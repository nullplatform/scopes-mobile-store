#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/platform/ios/setup
#
# Same contract as the android layer: downloads the ios asset into
# $WORKDIR/ios/app.ipa, checks the IPA layout and exports BINARY_PATH_IOS.
#
# Run: bats mobile-store/deployment/tests/platform/ios/setup_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/platform/ios/setup"

	export PLATFORMS="ios"
	export ASSETS_JSON='{"ios":{"url":"s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.ipa","asset_id":12,"build_id":10,"name":"ios"}}'
	export AWS_MOCK_S3_OBJECT="$TEST_TMP_DIR/fixture.ipa"
	make_fixture_ipa "$AWS_MOCK_S3_OBJECT"
}

teardown() {
	teardown_layer_test
}

@test "Should download the ios asset, validate the IPA layout and export BINARY_PATH_IOS" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Preparing the ios binary..."
	assert_line "   📡 Downloading s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.ipa to $WORKDIR/ios/app.ipa"
	assert_line "   ✅ BINARY_PATH_IOS=$WORKDIR/ios/app.ipa"
	assert_mock_call "$AWS_MOCK_CALLS_LOG" "aws s3 cp s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.ipa $WORKDIR/ios/app.ipa --region us-east-1"

	source "$SCRIPT"
	assert_equal "$BINARY_PATH_IOS" "$WORKDIR/ios/app.ipa"
}

@test "Should do nothing when ios is not one of the platforms of the scope" {
	export PLATFORMS="android"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 ios is not one of the platforms of this scope (android); nothing to do"
	[ ! -f "$AWS_MOCK_CALLS_LOG" ]
}

@test "Should fail with the full troubleshooting block when the file is not an IPA" {
	make_fixture_apk "$TEST_TMP_DIR/notanipa.apk"
	export AWS_MOCK_S3_OBJECT="$TEST_TMP_DIR/notanipa.apk"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ $WORKDIR/ios/app.ipa is not an iOS package: no Payload/*.app/Info.plist inside the archive"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI registered a file that is not an IPA as the 'ios' asset"
	assert_line "    • The download was truncated"
	assert_line "  🔧 How to fix:"
	assert_line "    • Make the CI upload the IPA produced by the Xcode archive as the 'ios' asset"
}

@test "Should fail with the full troubleshooting block when the bucket cannot be read" {
	export AWS_MOCK_S3_FAIL=1

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not download the ios binary from s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.ipa"
	assert_line "    • The agent role has no s3:GetObject permission on bucket 'assets-aws-mobile'"
	assert_line "    • Grant the agent role read access to s3://assets-aws-mobile"
}

#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/run_platforms
#
# The platform layers have no LAYER_VAR: run_platforms sources
# deployment/platform/<platform>/setup for every platform in PLATFORMS and
# exports BINARY_PATH_ANDROID and BINARY_PATH_IOS (empty for a platform the
# scope does not publish, so both outputs of the step always exist).
#
# Run: bats mobile-store/deployment/tests/scripts/run_platforms_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/scripts/run_platforms"
}

teardown() {
	teardown_layer_test
}

# A zip that passes both the APK and the IPA layout checks.
make_fixture_both() {
	local target="$1" dir
	dir=$(mktemp -d)
	mkdir -p "$dir/Payload/Sample.app"
	: > "$dir/Payload/Sample.app/Info.plist"
	: > "$dir/AndroidManifest.xml"
	(cd "$dir" && zip -qr "$target" Payload AndroidManifest.xml)
	rm -rf "$dir"
}

@test "Should prepare the android binary and export an empty BINARY_PATH_IOS" {
	export BINARY_PATH_IOS="/stale/from/another/run.ipa"

	source "$SCRIPT"

	assert_equal "$BINARY_PATH_ANDROID" "$WORKDIR/android/app.apk"
	assert_equal "$BINARY_PATH_IOS" ""
	assert_file_exists "$WORKDIR/android/app.apk"
	[ "$(bash -c 'echo "${BINARY_PATH_IOS-unset}"')" = "" ]
}

@test "Should log every platform it prepares" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Preparing the platform binaries (android)..."
	assert_line "🔍 Preparing the android binary..."
	assert_line "   ✅ BINARY_PATH_ANDROID=$WORKDIR/android/app.apk"
	assert_line "✨ Platform binaries ready"
}

@test "Should prepare android and ios when the scope publishes both" {
	export PLATFORMS="android ios"
	export ASSETS_JSON='{
		"android": {"url": "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"},
		"ios": {"url": "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.ipa"}
	}'
	make_fixture_both "$TEST_TMP_DIR/both.zip"
	export AWS_MOCK_S3_OBJECT="$TEST_TMP_DIR/both.zip"

	source "$SCRIPT"

	assert_equal "$BINARY_PATH_ANDROID" "$WORKDIR/android/app.apk"
	assert_equal "$BINARY_PATH_IOS" "$WORKDIR/ios/app.ipa"
	assert_mock_call "$AWS_MOCK_CALLS_LOG" "aws s3 cp s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.ipa $WORKDIR/ios/app.ipa --region us-east-1"
}

@test "Should fail when a platform layer fails" {
	export AWS_MOCK_S3_FAIL=1

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not download the android binary from s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
	refute_line "✨ Platform binaries ready"
}

@test "Should fail with the full troubleshooting block when PLATFORMS is empty" {
	export PLATFORMS=""

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ PLATFORMS is not set"
	assert_line "  💡 Possible causes:"
	assert_line "    • build_context did not run before the platform layers"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the deployment workflow from the start so build_context resolves the platforms of the scope"
}

@test "Should fail with the full troubleshooting block for a platform without a layer" {
	export PLATFORMS="android windows"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unknown platform 'windows': no layer at $SERVICE_PATH/deployment/platform/windows/setup"
	assert_line "  💡 Possible causes:"
	assert_line "    • PLATFORMS was not produced by build_context"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the deployment workflow from the start; the supported platforms are the directories under deployment/platform/"
	[ ! -f "$AWS_MOCK_CALLS_LOG" ]
}

@test "Should also work executed instead of sourced" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "✨ Platform binaries ready"
}

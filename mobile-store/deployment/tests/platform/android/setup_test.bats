#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/platform/android/setup
#
# The layer downloads the android asset of ASSETS_JSON into
# $WORKDIR/android/app.apk, checks it is an APK and exports BINARY_PATH_ANDROID.
# aws and curl are the mocks in tests/resources/mocks.
#
# Run: bats mobile-store/deployment/tests/platform/android/setup_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/platform/android/setup"
}

teardown() {
	teardown_layer_test
}

@test "Should download the android asset from s3, validate it and export BINARY_PATH_ANDROID" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Preparing the android binary..."
	assert_line "   📡 Downloading s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk to $WORKDIR/android/app.apk"
	assert_line "   ✅ BINARY_PATH_ANDROID=$WORKDIR/android/app.apk"
	assert_mock_call "$AWS_MOCK_CALLS_LOG" "aws s3 cp s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk $WORKDIR/android/app.apk --region us-east-1"

	source "$SCRIPT"
	assert_equal "$BINARY_PATH_ANDROID" "$WORKDIR/android/app.apk"
	assert_file_exists "$WORKDIR/android/app.apk"
}

@test "Should download the android asset with curl when the url is https" {
	export ASSETS_JSON='{"android":{"url":"https://assets-aws-mobile.s3.us-east-1.amazonaws.com/mobile/442353687/10/uat/app-release.apk","asset_id":6,"build_id":10}}'
	export CURL_MOCK_RESPONSE="$AWS_MOCK_S3_OBJECT"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ BINARY_PATH_ANDROID=$WORKDIR/android/app.apk"
	assert_mock_call "$CURL_MOCK_CALLS_LOG" "curl -fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time 300 --retry 2 -o $WORKDIR/android/app.apk https://assets-aws-mobile.s3.us-east-1.amazonaws.com/mobile/442353687/10/uat/app-release.apk"
	refute_line "aws s3 cp"
}

@test "Should do nothing when android is not one of the platforms of the scope" {
	export PLATFORMS="ios"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 android is not one of the platforms of this scope (ios); nothing to do"
	[ ! -f "$AWS_MOCK_CALLS_LOG" ]
}

@test "Should fail with the full troubleshooting block when the bucket cannot be read" {
	export AWS_MOCK_S3_FAIL=1

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not download the android binary from s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
	assert_line "  💡 Possible causes:"
	assert_line "    • The agent role has no s3:GetObject permission on bucket 'assets-aws-mobile'"
	assert_line "    • The asset was deleted from the bucket after the build"
	assert_line "  🔧 How to fix:"
	assert_line "    • Grant the agent role read access to s3://assets-aws-mobile"
	assert_line "    • Rebuild the release so the CI uploads the asset again"
}

@test "Should fail with the full troubleshooting block when the file is not an APK" {
	make_fixture_zip "$TEST_TMP_DIR/notanapk.zip"
	export AWS_MOCK_S3_OBJECT="$TEST_TMP_DIR/notanapk.zip"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ $WORKDIR/android/app.apk is not an Android package: no AndroidManifest.xml inside the archive"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI registered a file that is not an APK as the 'android-uat' asset"
	assert_line "    • The download was truncated"
	assert_line "  🔧 How to fix:"
	assert_line "    • Make the CI upload the APK produced by the Android build as the 'android-uat' asset"
}

@test "Should fail when ASSETS_JSON has no android entry" {
	export ASSETS_JSON='{}'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ ASSETS_JSON has no url for android"
	assert_line "  💡 Possible causes:"
	assert_line "    • build_context did not run, or it resolved the assets of another platform"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the deployment workflow from the start so build_context resolves the android asset"
}

@test "Should reject an asset url with an unsupported scheme" {
	export ASSETS_JSON='{"android":{"url":"ftp://host/app.apk","asset_id":6,"build_id":10}}'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unsupported asset url 'ftp://host/app.apk': only s3:// and https:// are supported"
}

# =============================================================================
# Hardening: the asset must live in the configured assets bucket
# =============================================================================
@test "Should reject an s3 url of another bucket" {
	export ASSETS_JSON='{"android":{"url":"s3://someone-elses-bucket/app.apk","asset_id":6,"build_id":10}}'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Asset URL is outside the configured assets bucket 'assets-aws-mobile': s3://someone-elses-bucket/app.apk"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI uploaded the asset to a bucket other than assets.bucket of the 'Mobile store' scope configuration"
	assert_line "    • The asset url was tampered with"
	assert_line "  🔧 How to fix:"
	assert_line "    • Make the CI upload the binaries to s3://assets-aws-mobile and register that url, or set assets.bucket to the bucket the CI uses"
	[ ! -f "$AWS_MOCK_CALLS_LOG" ]
}

@test "Should reject an https url of a host other than the assets bucket" {
	export CURL_MOCK_RESPONSE="$AWS_MOCK_S3_OBJECT"
	local url
	for url in "https://evil.example.com/app.apk" "https://assets-aws-mobile.s3.us-east-1.amazonaws.com.evil.example.com/app.apk" "https://evil.example.com/assets-aws-mobile.s3.amazonaws.com/app.apk" "https://other-bucket.s3.amazonaws.com/app.apk"; do
		export ASSETS_JSON="{\"android\":{\"url\":\"$url\",\"asset_id\":6,\"build_id\":10}}"

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Asset URL is outside the configured assets bucket 'assets-aws-mobile': $url"
		[ ! -f "$CURL_MOCK_CALLS_LOG" ]
	done
}

@test "Should accept the virtual-hosted https url of the assets bucket without a region" {
	export ASSETS_JSON='{"android":{"url":"https://assets-aws-mobile.s3.amazonaws.com/mobile/442353687/10/uat/app-release.apk","asset_id":6,"build_id":10}}'
	export CURL_MOCK_RESPONSE="$AWS_MOCK_S3_OBJECT"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ BINARY_PATH_ANDROID=$WORKDIR/android/app.apk"
}

# =============================================================================
# Real APKs have thousands of entries: the validation must not die of SIGPIPE
# under the pipefail the workflow session inherits.
# =============================================================================
@test "Should accept an APK with thousands of entries with pipefail active" {
	local dir="$TEST_TMP_DIR/big"
	mkdir -p "$dir/res"
	: > "$dir/AndroidManifest.xml"
	local i
	for i in $(seq 1 3200); do : > "$dir/res/f$i.xml"; done
	(cd "$dir" && zip -q "$TEST_TMP_DIR/big.apk" AndroidManifest.xml && zip -qr "$TEST_TMP_DIR/big.apk" res)
	export AWS_MOCK_S3_OBJECT="$TEST_TMP_DIR/big.apk"

	run bash -c 'set -euo pipefail; source "$0"; echo "exported=$BINARY_PATH_ANDROID"' "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ BINARY_PATH_ANDROID=$WORKDIR/android/app.apk"
	assert_line "exported=$WORKDIR/android/app.apk"
}

@test "Should fail with the troubleshooting block when the archive cannot be listed" {
	printf 'not a zip at all' > "$TEST_TMP_DIR/garbage.apk"
	export AWS_MOCK_S3_OBJECT="$TEST_TMP_DIR/garbage.apk"

	run bash -c 'set -euo pipefail; source "$0"' "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ $WORKDIR/android/app.apk is not an Android package: the file is not a zip archive"
	assert_line "  💡 Possible causes:"
	assert_line "    • The download was truncated"
}

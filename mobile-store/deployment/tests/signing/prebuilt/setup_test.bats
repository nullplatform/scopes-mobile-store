#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/signing/prebuilt/setup
#
# The CI already signed the binaries: the layer only promotes
# BINARY_PATH_<PLATFORM> to SIGNED_BINARY_PATH_<PLATFORM>.
#
# Run: bats mobile-store/deployment/tests/signing/prebuilt/setup_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/signing/prebuilt/setup"

	export BINARY_PATH_ANDROID="$WORKDIR/android/app.apk"
}

teardown() {
	teardown_layer_test
}

@test "Should export the CI-signed android binary as the signed one" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Signing layer 'prebuilt': the binaries are signed by the CI"
	assert_line "   ✅ android: using the CI-signed binary $WORKDIR/android/app.apk"

	source "$SCRIPT"
	assert_equal "$SIGNED_BINARY_PATH_ANDROID" "$WORKDIR/android/app.apk"
	assert_empty "${SIGNED_BINARY_PATH_IOS:-}" "SIGNED_BINARY_PATH_IOS"
}

@test "Should export both platforms when the scope publishes android and ios" {
	export PLATFORMS="android ios"
	export BINARY_PATH_IOS="$WORKDIR/ios/app.ipa"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ android: using the CI-signed binary $WORKDIR/android/app.apk"
	assert_line "   ✅ ios: using the CI-signed binary $WORKDIR/ios/app.ipa"

	source "$SCRIPT"
	assert_equal "$SIGNED_BINARY_PATH_ANDROID" "$WORKDIR/android/app.apk"
	assert_equal "$SIGNED_BINARY_PATH_IOS" "$WORKDIR/ios/app.ipa"
}

@test "Should fail with the full troubleshooting block when the platform binary was not prepared" {
	unset BINARY_PATH_ANDROID

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ BINARY_PATH_ANDROID is not set"
	assert_line "  💡 Possible causes:"
	assert_line "    • The platform/android layer did not run before the signing layer"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the deployment workflow from the start so the android binary is downloaded first"
}

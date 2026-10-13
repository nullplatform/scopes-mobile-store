#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/resolve_release_asset
#
# Usage: resolve_release_asset <semver> <platform>
# Prints the url of the '<platform>-<DIMENSION>' asset (type ASSET_TYPE) of
# the release with that semver, looked up with np release list / np asset list.
#
# Run: bats mobile-store/deployment/tests/scripts/resolve_release_asset_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/scripts/resolve_release_asset"
}

teardown() {
	teardown_layer_test
}

@test "Should print the url of the platform asset of the release" {
	run bash "$SCRIPT" 0.9.0 android

	assert_equal "$status" "0"
	assert_equal "$output" "s3://assets-aws-mobile/mobile/442353687/442353600/uat/app-release.apk"
	assert_np_called "np release list --application-id 442353687 --limit 200 --format json"
	assert_np_called "np asset list --build-id 442353600 --format json"
}

@test "Should resolve the ios asset too" {
	run bash "$SCRIPT" 0.9.0 ios

	assert_equal "$status" "0"
	assert_equal "$output" "s3://assets-aws-mobile/mobile/442353687/442353600/uat/app-release.ipa"
}

@test "Should fail with the full troubleshooting block when the release does not exist" {
	run bash "$SCRIPT" 0.1.0 android

	assert_equal "$status" "1"
	assert_line "   ❌ No release 0.1.0 in application 442353687"
	assert_line "  💡 Possible causes:"
	assert_line "    • The release was deleted, or it belongs to another application"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check the releases of the application: np release list --application-id 442353687"
}

@test "Should fail with the full troubleshooting block when the release has no asset for the platform" {
	export NP_MOCK_ASSET_LIST="$MOCKS_DIR/asset_list.json"

	run bash "$SCRIPT" 0.9.0 ios

	assert_equal "$status" "1"
	assert_line "   ❌ No asset named 'ios-uat' of type 'bundle' in release 0.9.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI of release 0.9.0 did not build a binary for the 'uat' environment"
	assert_line "    • The asset was registered with another name"
}

@test "Should fail when np cannot list the releases" {
	unset NP_MOCK_RELEASE_LIST

	run bash "$SCRIPT" 0.9.0 android

	assert_equal "$status" "1"
	assert_line "   ❌ Could not list the releases of application 442353687 (np release list failed)"
}

@test "Should reject bad arguments" {
	run bash "$SCRIPT" 0.9.0

	assert_equal "$status" "1"
	assert_line "   ❌ Usage: resolve_release_asset <semver> <platform>"

	run bash "$SCRIPT" "0.9.0" "../android"
	assert_equal "$status" "1"
	assert_line "   ❌ Invalid platform '../android': only lowercase letters, digits and dashes are allowed"
}

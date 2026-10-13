#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/resolve_release_asset
#
# Usage: resolve_release_asset <semver> <platform>
# Prints the url of the asset of that platform (named after the scope's asset
# name, see scripts/asset_names) of type ASSET_TYPE of the release with that
# semver, looked up with np release list / np asset list.
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
	export PLATFORMS="android ios"

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
	export PLATFORMS="android ios"

	run bash "$SCRIPT" 0.9.0 ios

	assert_equal "$status" "1"
	assert_line "   ❌ No asset named 'ios' of type 'bundle' in release 0.9.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI of release 0.9.0 did not register an asset named 'ios'"
	assert_line "    • The scope's asset name changed after release 0.9.0 was built"
	assert_line "  🔧 How to fix:"
	assert_line "    • Roll back by deploying another release that carries an 'ios' asset"
}

# =============================================================================
# Asset names: the same rule as build_context (scripts/asset_names)
# =============================================================================
write_previous_listing() {
	local names="$1"
	jq -n --arg names "$names" '{results: ($names | split(" ") | to_entries | map({
		id: (100 + .key), build_id: 442353600, name: .value, type: "bundle",
		url: ("s3://assets-aws-mobile/mobile/442353687/442353600/" + .value + "/app"), metadata: {}
	}))}' > "$TEST_TMP_DIR/previous_assets.json"
	export NP_MOCK_ASSET_LIST="$TEST_TMP_DIR/previous_assets.json"
}

@test "Should pick the asset named by ASSET_NAME, not by the dimension" {
	export ASSET_NAME="android-internal"
	export DIMENSION="uat"
	write_previous_listing "android android-internal"

	run bash "$SCRIPT" 0.9.0 android

	assert_equal "$status" "0"
	assert_equal "$output" "s3://assets-aws-mobile/mobile/442353687/442353600/android-internal/app"
}

@test "Should swap the platform prefix for the other platform of a both scope" {
	export PLATFORMS="android ios"
	export ASSET_NAME="android-internal"
	write_previous_listing "android-internal ios-internal ios"

	run bash "$SCRIPT" 0.9.0 ios

	assert_equal "$status" "0"
	assert_equal "$output" "s3://assets-aws-mobile/mobile/442353687/442353600/ios-internal/app"
}

@test "Should use ios when the asset name is android in a both scope" {
	export PLATFORMS="android ios"
	export ASSET_NAME="android"
	write_previous_listing "android ios"

	run bash "$SCRIPT" 0.9.0 ios

	assert_equal "$status" "0"
	assert_equal "$output" "s3://assets-aws-mobile/mobile/442353687/442353600/ios/app"
}

@test "Should fail when the other platform's asset name cannot be derived" {
	export PLATFORMS="android ios"
	export ASSET_NAME="mobile-prod"

	run bash "$SCRIPT" 0.9.0 ios

	assert_equal "$status" "1"
	assert_line "   ❌ Cannot derive the ios asset name from the scope's asset name 'mobile-prod'"
	refute_np_called "release list"
}

@test "Should resolve the asset name from the scope in the context when ASSET_NAME is not set" {
	unset ASSET_NAME
	CONTEXT=$(echo "$CONTEXT" | jq -c '.scope.asset_name = "android-internal"')
	write_previous_listing "android-internal"

	run bash "$SCRIPT" 0.9.0 android

	assert_equal "$status" "0"
	assert_equal "$output" "s3://assets-aws-mobile/mobile/442353687/442353600/android-internal/app"
}

@test "Should default to the platform when no asset name is known" {
	unset ASSET_NAME
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')
	echo '{"id": 7, "asset_name": null}' > "$TEST_TMP_DIR/scope.json"
	export NP_MOCK_SCOPE_READ="$TEST_TMP_DIR/scope.json"
	write_previous_listing "android-internal android"

	run bash "$SCRIPT" 0.9.0 android

	assert_equal "$status" "0"
	assert_equal "$output" "s3://assets-aws-mobile/mobile/442353687/442353600/android/app"
}

@test "Should fail when no asset name is known and the scope cannot be read" {
	unset ASSET_NAME
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')

	run bash "$SCRIPT" 0.9.0 android

	assert_equal "$status" "1"
	assert_line "   ❌ Could not read scope '7' to resolve its asset name"
	assert_line "   📋 np scope read answered: {\"error\": \"no mock response configured for: np \"}"
	refute_np_called "release list"
}

@test "Should fail when the scope read answers another scope" {
	unset ASSET_NAME
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')
	echo '{"id": 8, "asset_name": "android-prod"}' > "$TEST_TMP_DIR/scope.json"
	export NP_MOCK_SCOPE_READ="$TEST_TMP_DIR/scope.json"

	run bash "$SCRIPT" 0.9.0 android

	assert_equal "$status" "1"
	assert_line "   ❌ Could not read scope '7' to resolve its asset name"
}

@test "Should reject an invalid ASSET_NAME" {
	export ASSET_NAME="../prod"

	run bash "$SCRIPT" 0.9.0 android

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid asset name '../prod': it must match ^[a-z0-9][a-z0-9._-]*\$ (lowercase letters, digits, dots, underscores and dashes, starting with a letter or digit)"
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

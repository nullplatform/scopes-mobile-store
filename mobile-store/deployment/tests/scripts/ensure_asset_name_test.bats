#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/ensure_asset_name
#
# create-scope and update-scope make sure the scope has an asset_name: the
# platform rejects a deployment of a scope without one. A missing name is set
# to the first platform of the scope; an existing one is validated and kept.
#
# Run: bats mobile-store/deployment/tests/scripts/ensure_asset_name_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/scripts/ensure_asset_name"

	unset ASSET_NAME
	echo '{"id": 7, "asset_name": "android"}' > "$TEST_TMP_DIR/scope_patch.json"
}

teardown() {
	teardown_layer_test
}

without_asset_name() {
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')
	echo '{"id": 7, "asset_name": null}' > "$TEST_TMP_DIR/scope_read.json"
	export NP_MOCK_SCOPE_READ="$TEST_TMP_DIR/scope_read.json"
}

@test "Should keep the asset name the scope already has" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ Asset name: android-uat (set in the scope)"
	refute_np_called "scope patch"
}

@test "Should set the asset name to the first platform when the scope has none" {
	without_asset_name
	export NP_MOCK_SCOPE_PATCH="$TEST_TMP_DIR/scope_patch.json"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_np_called "np scope read --id 7 --format json"
	assert_np_called "np scope patch --id 7 --body {\"asset_name\":\"android\"} --format json"
	assert_line "   ✅ Asset name: android (the scope had none; set to its first platform)"
}

@test "Should set the asset name to ios for an ios scope" {
	without_asset_name
	export PLATFORMS="ios"
	export NP_MOCK_SCOPE_PATCH="$TEST_TMP_DIR/scope_patch.json"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_np_called "np scope patch --id 7 --body {\"asset_name\":\"ios\"} --format json"
}

@test "Should keep the asset name the scope has even when the context does not carry it" {
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')
	echo '{"id": 7, "asset_name": "android-production"}' > "$TEST_TMP_DIR/scope_read.json"
	export NP_MOCK_SCOPE_READ="$TEST_TMP_DIR/scope_read.json"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ Asset name: android-production (set in the scope)"
	refute_np_called "scope patch"
}

@test "Should fail with the troubleshooting block when the scope cannot be patched" {
	without_asset_name

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not set the asset name of scope 7 to 'android'"
	assert_line "  💡 Possible causes:"
	assert_line "    • The agent API key cannot update scopes"
	assert_line "  🔧 How to fix:"
	assert_line "    • np scope patch --id 7 --body '{\"asset_name\":\"android\"}'"
}

@test "Should fail when the scope cannot be read and the context carries no asset name" {
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not read scope 7 to check its asset name"
	refute_np_called "scope patch"
}

@test "Should reject an invalid asset name without changing it" {
	CONTEXT=$(echo "$CONTEXT" | jq -c '.scope.asset_name = "Android UAT"')

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid asset name 'Android UAT': it must match ^[a-z0-9][a-z0-9._-]*\$ (lowercase letters, digits, dots, underscores and dashes, starting with a letter or digit)"
	refute_np_called "scope patch"
}

@test "Should reject an asset name the ios name cannot be derived from in a both scope" {
	export PLATFORMS="android ios"
	CONTEXT=$(echo "$CONTEXT" | jq -c '.scope.asset_name = "mobile-prod"')

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Cannot derive the ios asset name from the scope's asset name 'mobile-prod'"
}

@test "Should fail when the scope id is not an integer" {
	export SCOPE_ID="7; rm -rf /"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid scope id '7; rm -rf /': must be an integer"
	refute_np_called "scope"
}

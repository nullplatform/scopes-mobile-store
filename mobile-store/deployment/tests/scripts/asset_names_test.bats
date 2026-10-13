#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/asset_names (sourced library)
#
# The scope's asset_name is the source of truth for the binary a deployment
# picks: it is the asset of the first platform; the other platform of a
# 'both' scope swaps the platform prefix.
#
# Run: bats mobile-store/deployment/tests/scripts/asset_names_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	MOCKS_DIR="$DEPLOYMENT_DIR/tests/resources/mocks"
	LIB="$DEPLOYMENT_DIR/scripts/asset_names"

	TEST_TMP_DIR=$(mktemp -d)
	export PATH="$MOCKS_DIR:$PATH"
	export NP_MOCK_CALLS_LOG="$TEST_TMP_DIR/np_calls.log"
	export CONTEXT
	CONTEXT=$(cat "$DEPLOYMENT_DIR/tests/resources/context_initial.json")
	export SCOPE_ID="7"
	unset NP_MOCK_SCOPE_READ NP_MOCK_SCOPE_PATCH

	source "$LIB"
}

teardown() {
	rm -rf "$TEST_TMP_DIR"
}

write_scope_read() {
	echo "$1" > "$TEST_TMP_DIR/scope_read.json"
	export NP_MOCK_SCOPE_READ="$TEST_TMP_DIR/scope_read.json"
}

# =============================================================================
# platform_asset_name <asset name> <primary platform> <platform>
# =============================================================================
@test "Should use the asset name as is for the primary platform" {
	run platform_asset_name "mobile-prod" android android

	assert_equal "$status" "0"
	assert_equal "$output" "mobile-prod"
}

@test "Should swap the platform prefix for the other platform" {
	run platform_asset_name "android-internal" android ios

	assert_equal "$status" "0"
	assert_equal "$output" "ios-internal"
}

@test "Should use the bare platform when the asset name is the primary platform" {
	run platform_asset_name "android" android ios

	assert_equal "$status" "0"
	assert_equal "$output" "ios"
}

@test "Should swap only a prefix followed by a dash" {
	run platform_asset_name "android-prod" android ios
	assert_equal "$output" "ios-prod"

	for name in androidtv-prod android2 androidx; do
		run platform_asset_name "$name" android ios
		assert_equal "$status" "1"
		assert_line "   ❌ Cannot derive the ios asset name from the scope's asset name '$name'"
	done
}

@test "Should fail with the convention for both when the other name cannot be derived" {
	run platform_asset_name "mobile-prod" android ios

	assert_equal "$status" "1"
	assert_line "   ❌ Cannot derive the ios asset name from the scope's asset name 'mobile-prod'"
	assert_line "  💡 Possible causes:"
	assert_line "    • The scope deploys android and ios, and its asset name is neither 'android' (its first platform) nor starts with 'android-'"
	assert_line "  🔧 How to fix:"
	assert_line "    • For a scope with both platforms, name its asset 'android' or 'android-<suffix>': the ios binary is then 'ios' or 'ios-<suffix>'"
	assert_line "    • np scope patch --id 7 --body '{\"asset_name\":\"android\"}'"
}

# =============================================================================
# validate_asset_name <name>
# =============================================================================
@test "Should accept asset names made of lowercase letters, digits, dots, underscores and dashes" {
	for name in android ios android-internal app.v2 my_app 9lives; do
		run validate_asset_name "$name"
		assert_equal "$status" "0"
	done
}

@test "Should reject an invalid asset name with the troubleshooting block" {
	for name in "Android" "../prod" "-android" "android prod" ".hidden"; do
		run validate_asset_name "$name"
		assert_equal "$status" "1"
		assert_line "   ❌ Invalid asset name '$name': it must match ^[a-z0-9][a-z0-9._-]*\$ (lowercase letters, digits, dots, underscores and dashes, starting with a letter or digit)"
	done
	assert_line "  💡 Possible causes:"
	assert_line "    • The scope's asset name was set by hand with unsupported characters"
	assert_line "  🔧 How to fix:"
	assert_line "    • np scope patch --id 7 --body '{\"asset_name\":\"android\"}'"
}

# =============================================================================
# resolve_scope_asset_name <primary platform>
#   sets RESOLVED_ASSET_NAME and RESOLVED_ASSET_NAME_SOURCE
# =============================================================================
@test "Should take the asset name from the scope in the context" {
	resolve_scope_asset_name android

	assert_equal "$RESOLVED_ASSET_NAME" "android"
	assert_equal "$RESOLVED_ASSET_NAME_SOURCE" "context"
	refute_np_called "scope read"
}

@test "Should read the scope when the context carries no asset name" {
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')
	write_scope_read '{"id": 7, "asset_name": "android-internal"}'

	resolve_scope_asset_name android

	assert_equal "$RESOLVED_ASSET_NAME" "android-internal"
	assert_equal "$RESOLVED_ASSET_NAME_SOURCE" "scope"
	assert_np_called "np scope read --id 7 --format json"
}

@test "Should treat a null asset name in the context as missing" {
	CONTEXT=$(echo "$CONTEXT" | jq -c '.scope.asset_name = null')
	write_scope_read '{"id": 7, "asset_name": "android-internal"}'

	resolve_scope_asset_name android

	assert_equal "$RESOLVED_ASSET_NAME" "android-internal"
}

@test "Should default to the primary platform when neither the context nor the scope has an asset name" {
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')
	write_scope_read '{"id": 7, "asset_name": null}'

	resolve_scope_asset_name ios

	assert_equal "$RESOLVED_ASSET_NAME" "ios"
	assert_equal "$RESOLVED_ASSET_NAME_SOURCE" "default"
}

@test "Should fail, not default, when the scope cannot be read" {
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')

	run resolve_scope_asset_name android

	assert_equal "$status" "1"
	assert_line "   ❌ Could not read scope '7' to resolve its asset name"
	assert_line "   📋 np scope read answered: {\"error\": \"no mock response configured for: np \"}"
	assert_line "  💡 Possible causes:"
	assert_line "    • The agent API key cannot read the scope"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check that the agent API key can read it: np scope read --id 7 --format json"
}

@test "Should fail when the scope read answers something that is not the scope" {
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')
	for answer in 'not json' '[]' '{"id": 8, "asset_name": null}' '{"results": []}' 'null'; do
		write_scope_read "$answer"

		run resolve_scope_asset_name android

		assert_equal "$status" "1"
		assert_line "   ❌ Could not read scope '7' to resolve its asset name"
	done
}

@test "Should use the scope id of the context when SCOPE_ID is not set" {
	unset SCOPE_ID
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.scope.asset_name)')
	write_scope_read '{"id": 7, "asset_name": "android-internal"}'

	resolve_scope_asset_name android

	assert_equal "$RESOLVED_ASSET_NAME" "android-internal"
	assert_np_called "np scope read --id 7 --format json"
}

@test "Should fail when the scope's asset name is invalid" {
	CONTEXT=$(echo "$CONTEXT" | jq -c '.scope.asset_name = "../prod"')

	run resolve_scope_asset_name android

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid asset name '../prod': it must match ^[a-z0-9][a-z0-9._-]*\$ (lowercase letters, digits, dots, underscores and dashes, starting with a letter or digit)"
}

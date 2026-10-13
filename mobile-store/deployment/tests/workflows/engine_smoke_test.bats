#!/usr/bin/env bats
# =============================================================================
# Smoke test of the real engine: runs deployment/workflows/{initial,rollback}.yaml
# with `np service workflow exec` (one bash -c that sources every step, joined
# by &&) and the CLI mocks of tests/resources/mocks for everything else (np
# API calls, aws, firebase). No --build-context: CONTEXT comes from the
# environment, so no API call and no credentials are needed.
#
# Skipped when the real np CLI is not installed.
#
# Run: bats mobile-store/deployment/tests/workflows/engine_smoke_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

	REAL_NP=$(command -v np || true)
	if [ -z "$REAL_NP" ] || ! "$REAL_NP" service workflow exec --help 2>/dev/null | grep -q -- "--workflow"; then
		skip "the np CLI is required for the engine smoke test"
	fi

	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"

	# What build_context resolves from the context, not from the layer defaults.
	unset DIMENSION PLATFORMS CHANNEL ROLLOUT_PERCENTAGE RELEASE_SEMVER APPLICATION_SLUG SIGNING_LAYER \
		DISTRIBUTION_LAYER GATE_LAYER ASSETS_BUCKET ASSETS_REGION ASSET_TYPE ASSETS_JSON SCOPE_CONFIGURATION \
		ANDROID_PACKAGE IOS_BUNDLE_ID PREVIOUS_DEPLOYMENT_ID PREVIOUS_RELEASE_SEMVER WORKDIR_BASE
	unset NP_MOCK_SPECIFICATION_LIST NP_MOCK_PROVIDER_LIST
	export CONTEXT
	CONTEXT=$(jq -c '.providers["scope-configurations"].firebase.app_id_android = "1:726762523137:android:a700b1fa49f91e41eb0e00"' \
		"$RESOURCES_DIR/context_initial.json")
	export WORKDIR="$TEST_TMP_DIR/work"
	export NP_MOCK_ASSET_LIST="$MOCKS_DIR/asset_list.json"
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list.json"
	export NP_MOCK_RELEASE_READ="$MOCKS_DIR/release_read.json"
	write_service_account "$TEST_TMP_DIR/sa.json"
	write_mock_secret "mobile/firebase-sa" "$(cat "$TEST_TMP_DIR/sa.json")"
}

teardown() {
	if [ -n "${TEST_TMP_DIR:-}" ]; then
		teardown_layer_test
	fi
}

run_engine() {
	run bash -c 'cd "$1" && "$0" service workflow exec --workflow "$2" 2>&1' \
		"$REAL_NP" "$SERVICE_PATH" "$SERVICE_PATH/deployment/workflows/$1.yaml"
}

@test "Should run the whole initial workflow through the engine and record the distribution" {
	run_engine initial

	assert_equal "$status" "0"
	[[ "$output" == *"Executing step: publish"* ]]
	assert_line "✨ Publish complete"
	assert_json_equal "$(jq -c '{provider, group, channel, rollout_percentage, releases: (.releases | keys)}' "$WORKDIR/77/distribution.json")" '{
		"provider": "firebase",
		"group": "internal",
		"channel": "internal",
		"rollout_percentage": 100,
		"releases": ["android"]
	}' "distribution.json"
	assert_file_not_exists "$WORKDIR/77/firebase-sa.json"
	assert_np_called "np deployment patch --id 77"
}

@test "Should roll back through the engine to the previous release" {
	export NP_MOCK_ASSET_LIST="$MOCKS_DIR/asset_list_previous.json"

	run_engine rollback

	assert_equal "$status" "0"
	assert_line "✨ Rollback complete"
	assert_equal "$(jq -r '.rollback_to' "$WORKDIR/77/distribution.json")" "0.9.0"
	assert_file_not_exists "$WORKDIR/77/firebase-sa.json"
}

@test "Should stop the chain at the first failing step" {
	export CONTEXT
	CONTEXT=$(echo "$CONTEXT" | jq -c '.scope.capabilities.platform = "windows"')

	run_engine initial

	assert_equal "$status" "1"
	assert_line "   ❌ Unsupported platform 'windows'"
	[[ "$output" == *"Executing step: build context"* ]]
	[[ "$output" != *"Executing step: platform layers"* ]]
	[ ! -f "$AWS_MOCK_CALLS_LOG" ] || ! grep -q "s3 cp" "$AWS_MOCK_CALLS_LOG"
}

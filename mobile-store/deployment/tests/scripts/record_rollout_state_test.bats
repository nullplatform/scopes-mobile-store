#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/record_rollout_state
#
# switch_traffic and finalize have nothing to change on Firebase App
# Distribution (no staged rollout): the step records the final state on the
# deployment as a message, like do_publish. Public stores have no layer yet
# and fail with a clear message. np is the mock in tests/resources/mocks.
#
# Run: bats mobile-store/deployment/tests/scripts/record_rollout_state_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/scripts/record_rollout_state"
	export ROLLOUT_ACTION="switch_traffic"
}

teardown() {
	teardown_layer_test
}

patched_message() {
	grep -F "np deployment patch" "$NP_MOCK_CALLS_LOG" | sed 's/^np deployment patch --id 77 --body //; s/ --format json$//' | jq -c '.messages[0] | del(.timestamp)'
}

@test "Should record switch_traffic on Firebase without touching Firebase" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 switch_traffic on distribution 'firebase'"
	assert_line "   📋 Firebase App Distribution has no staged rollout: release 1.0.0 is already available to all of group 'internal'"
	assert_line "   ✅ Recorded the rollout state on deployment 77 (message MOBILE_STORE_ROLLOUT)"
	assert_json_equal "$(patched_message)" '{
		"level": "INFO",
		"code": "MOBILE_STORE_ROLLOUT",
		"message": "mobile-store switch_traffic: Firebase App Distribution has no staged rollout: release 1.0.0 is already available to all of group '"'internal'"'"
	}' "deployment message"
	[ ! -f "$FIREBASE_MOCK_LOG" ]
}

@test "Should record finalize on Firebase" {
	export ROLLOUT_ACTION="finalize"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 finalize on distribution 'firebase'"
	assert_line "   📋 Release 1.0.0 stays the latest build of Firebase group 'internal'; nothing to change on Firebase"
	assert_json_equal "$(patched_message)" '{
		"level": "INFO",
		"code": "MOBILE_STORE_ROLLOUT",
		"message": "mobile-store finalize: Release 1.0.0 stays the latest build of Firebase group '"'internal'"'; nothing to change on Firebase"
	}' "deployment message"
}

@test "Should not fail when the deployment cannot be patched" {
	unset NP_MOCK_DEPLOYMENT_PATCH

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not record the rollout state on deployment 77 (np deployment patch failed)"
}

@test "Should fail with the full troubleshooting block for a public store without a layer" {
	export DISTRIBUTION_LAYER="google-play"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ switch_traffic is not supported for distribution 'google-play' yet"
	assert_line "  💡 Possible causes:"
	assert_line "    • The google-play distribution layer (staged rollout on the store) is not implemented yet"
	assert_line "  🔧 How to fix:"
	assert_line "    • Use the firebase distribution layer for this scope until google-play is supported"
	refute_np_called "deployment patch"
}

@test "Should fail for finalize on the app store too" {
	export ROLLOUT_ACTION="finalize"
	export DISTRIBUTION_LAYER="app-store"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ finalize is not supported for distribution 'app-store' yet"
}

@test "Should fail with the full troubleshooting block on an unknown ROLLOUT_ACTION" {
	export ROLLOUT_ACTION="promote"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unknown ROLLOUT_ACTION 'promote': expected switch_traffic or finalize"
	assert_line "  💡 Possible causes:"
	assert_line "    • The workflow step that runs record_rollout_state sets configuration.ROLLOUT_ACTION to an unexpected value"
	assert_line "  🔧 How to fix:"
	assert_line "    • Set ROLLOUT_ACTION to switch_traffic or finalize in the workflow step configuration"
}

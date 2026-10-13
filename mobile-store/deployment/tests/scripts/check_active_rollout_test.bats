#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/check_active_rollout
#
# A blue-green deployment must not start while another deployment of the
# scope is still rolling out (creating, running, waiting_for_instances, or
# the candidate of the scope). np is the mock in tests/resources/mocks.
#
# Run: bats mobile-store/deployment/tests/scripts/check_active_rollout_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/scripts/check_active_rollout"

	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list.json"
}

teardown() {
	teardown_layer_test
}

# deployment_list_with <id> <status> <status_in_scope>: the shared listing plus one deployment.
deployment_list_with() {
	jq --argjson id "$1" --arg status "$2" --arg in_scope "$3" \
		'.results = [{id: $id, scope_id: 7, release_id: 99, status: $status, status_in_scope: $in_scope, strategy: "blue_green", created_at: "2025-12-24T10:00:00.000Z"}] + .results' \
		"$MOCKS_DIR/deployment_list.json" > "$TEST_TMP_DIR/deployment_list.json"
	export NP_MOCK_DEPLOYMENT_LIST="$TEST_TMP_DIR/deployment_list.json"
}

assert_rollout_refused() {
	local id="$1"
	assert_equal "$status" "1"
	assert_line "   ❌ A rollout is already in progress (deployment $id); finalize or roll it back first"
	assert_line "  💡 Possible causes:"
	assert_line "    • Deployment $id of scope 7 has not been finalized or rolled back yet"
	assert_line "  🔧 How to fix:"
	assert_line "    • Finalize deployment $id (or roll it back) and start this deployment again"
}

@test "Should pass when the only deployment in progress is the current one" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Checking that no other rollout is in progress in scope 7..."
	assert_line "   ✅ No other rollout in progress in scope 7"
	assert_np_called "np deployment list --scope-id 7 --all --max-pages 5 --format json"
}

@test "Should refuse while another deployment is running" {
	deployment_list_with 79 running inactive

	run source "$SCRIPT"

	assert_rollout_refused 79
}

@test "Should refuse while another deployment is creating" {
	deployment_list_with 79 creating inactive

	run source "$SCRIPT"

	assert_rollout_refused 79
}

@test "Should refuse while another deployment is waiting for instances" {
	deployment_list_with 79 waiting_for_instances inactive

	run source "$SCRIPT"

	assert_rollout_refused 79
}

@test "Should refuse while another deployment is in any in-progress status" {
	local deployment_status
	for deployment_status in creating creating_approval running waiting_for_instances switching_traffic finalizing rolling_back cancelling; do
		deployment_list_with 79 "$deployment_status" inactive

		run source "$SCRIPT"

		assert_rollout_refused 79
	done
}

@test "Should refuse while another deployment is the candidate of the scope with a non-terminal status" {
	deployment_list_with 79 some_new_status candidate

	run source "$SCRIPT"

	assert_rollout_refused 79
}

@test "Should not block on a terminal deployment left as the candidate of the scope" {
	local deployment_status
	for deployment_status in failed cancelled canceled rolled_back finalized deleted deleting creating_approval_denied; do
		deployment_list_with 79 "$deployment_status" candidate

		run source "$SCRIPT"

		assert_equal "$status" "0"
		assert_line "   ✅ No other rollout in progress in scope 7"
	done
}

@test "Should pass when the scope has no deployments" {
	echo '{"results":[]}' > "$TEST_TMP_DIR/empty.json"
	export NP_MOCK_DEPLOYMENT_LIST="$TEST_TMP_DIR/empty.json"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ No other rollout in progress in scope 7"
}

@test "Should fail closed with the full troubleshooting block when the deployments cannot be listed" {
	unset NP_MOCK_DEPLOYMENT_LIST

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not list the deployments of scope 7 to check for a rollout in progress"
	assert_line "  💡 Possible causes:"
	assert_line "    • The nullplatform API is unavailable or the agent API key cannot read the deployments of the scope"
	assert_line "  🔧 How to fix:"
	assert_line "    • Retry the deployment; if it keeps failing, check the agent API key permissions on the scope"
}

@test "Should take the scope and deployment from CONTEXT when they are not exported" {
	unset SCOPE_ID DEPLOYMENT_ID
	deployment_list_with 77 running candidate

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_np_called "np deployment list --scope-id 7 --all --max-pages 5 --format json"
}

@test "Should fail with the full troubleshooting block when the scope id is not an integer" {
	export SCOPE_ID="7; rm -rf /"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid scope id '7; rm -rf /' or deployment id '77': both must be integers"
	assert_line "  💡 Possible causes:"
	assert_line "    • The context was not produced by the platform"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run this step from a workflow executed with np service workflow exec --build-context"
}

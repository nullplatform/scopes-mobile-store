#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/delete_deployment
#
# Firebase App Distribution cannot unpublish a release: deleting a deployment
# (also a failed one) only removes its scratch directory. It never depends on
# build_context, which may be what failed in the first place.
#
# Run: bats mobile-store/deployment/tests/scripts/delete_deployment_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/scripts/delete_deployment"

	# What the workflow has: WORKDIR from values.yaml, no build_context.
	export WORKDIR="$TEST_TMP_DIR/work"
	unset WORKDIR_BASE
	mkdir -p "$WORKDIR/77/android"
	: > "$WORKDIR/77/android/app.apk"
}

teardown() {
	teardown_layer_test
}

@test "Should remove the scratch directory of the deployment and leave Firebase alone" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Deleting deployment 77 (status creating)"
	assert_line "   📋 Firebase App Distribution cannot unpublish a release: the releases of this deployment stay in the console"
	assert_line "   ✅ Removed the scratch directory $WORKDIR/77"
	assert_line "✨ Deployment 77 deleted"
	[ ! -d "$WORKDIR/77" ]
	[ ! -f "$FIREBASE_MOCK_LOG" ]
}

@test "Should clean up a failed deployment" {
	CONTEXT=$(echo "$CONTEXT" | jq -c '.deployment.status = "failed"')

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Deleting deployment 77 (status failed)"
	assert_line "✨ Deployment 77 deleted"
}

@test "Should succeed when there is nothing to remove" {
	rm -rf "$WORKDIR/77"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 No scratch directory to remove ($WORKDIR/77)"
}

@test "Should not remove anything when the deployment id is not an integer" {
	export DEPLOYMENT_ID=".."

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Deployment id '..' is not an integer; nothing removed"
	assert_directory_exists "$WORKDIR/77"
}

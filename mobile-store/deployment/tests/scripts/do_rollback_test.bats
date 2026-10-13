#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/do_rollback
#
# Runs deployment/distribution/$DISTRIBUTION_LAYER/rollback (an executable)
# and records the result on the deployment as a message, best effort.
#
# Run: bats mobile-store/deployment/tests/scripts/do_rollback_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/scripts/do_rollback"

	export SERVICE_PATH="$TEST_TMP_DIR/service"
	export DISTRIBUTION_LAYER="fake"
	mkdir -p "$SERVICE_PATH/deployment/distribution/fake"
	cat > "$SERVICE_PATH/deployment/distribution/fake/rollback" <<'SCRIPT'
#!/bin/bash
echo "fake rollback to $PREVIOUS_RELEASE_SEMVER"
printf '{"provider":"fake","rollback_to":"%s","releases":{}}' "$PREVIOUS_RELEASE_SEMVER" > "$WORKDIR/distribution.json"
SCRIPT
	chmod +x "$SERVICE_PATH/deployment/distribution/fake/rollback"
}

teardown() {
	teardown_layer_test
}

@test "Should run the rollback of the distribution layer and record it on the deployment" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📝 Rolling back through the 'fake' distribution layer..."
	assert_line "fake rollback to 0.9.0"
	assert_line "   ✅ Recorded the rollback on deployment 77 (message MOBILE_STORE_ROLLBACK)"
	assert_line "✨ Rollback complete"
	local message
	message=$(grep -F "np deployment patch" "$NP_MOCK_CALLS_LOG" | sed 's/^np deployment patch --id 77 --body //; s/ --format json$//' | jq -c '.messages[0] | del(.timestamp)')
	assert_json_equal "$message" '{
		"level": "INFO",
		"code": "MOBILE_STORE_ROLLBACK",
		"message": "mobile-store rollback: {\"provider\":\"fake\",\"rollback_to\":\"0.9.0\",\"releases\":{}}"
	}' "deployment message"
}

@test "Should propagate a rollback failure without touching the deployment" {
	printf '#!/bin/bash\necho "fake rollback failed" >&2\nexit 3\n' > "$SERVICE_PATH/deployment/distribution/fake/rollback"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "fake rollback failed"
	refute_line "✨ Rollback complete"
	refute_np_called "deployment patch"
}

@test "Should fail with the full troubleshooting block when the layer has no rollback" {
	export DISTRIBUTION_LAYER="google-play"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The distribution layer 'google-play' has no rollback"
	assert_line "  💡 Possible causes:"
	assert_line "    • 'google-play' is not implemented yet, or its rollback script is missing or not executable"
	assert_line "    • Expected an executable at: $SERVICE_PATH/deployment/distribution/google-play/rollback"
	assert_line "  🔧 How to fix:"
	assert_line "    • Roll back by hand in the google-play console, or set distribution_layer to an implementation under deployment/distribution/ that has a rollback"
}

@test "Should reject a distribution layer name with path characters" {
	export DISTRIBUTION_LAYER="../fake"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid distribution implementation name '../fake': only lowercase letters, digits and dashes are allowed"
}

#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/gate/none/setup
#
# No external approval: the layer only exports GATE_RESULT=approved.
#
# Run: bats mobile-store/deployment/tests/gate/none/setup_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/gate/none/setup"
}

teardown() {
	teardown_layer_test
}

@test "Should approve without an external gate" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Gate layer 'none'"
	assert_line "   ✅ No external approval required for channel 'internal'"

	source "$SCRIPT"
	assert_equal "$GATE_RESULT" "approved"
}

@test "Should name the channel of the scope" {
	export CHANNEL="production"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ No external approval required for channel 'production'"
}

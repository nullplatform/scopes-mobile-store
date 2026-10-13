#!/usr/bin/env bats
# =============================================================================
# Unit tests for mobile-store/scripts/no_op
#
# Run: bats mobile-store/scope/tests/no_op_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SCOPE_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$SCOPE_DIR/.." && pwd)/testing/assertions.sh"
	source "$SCOPE_DIR/deployment/tests/helpers.bash"
	SCRIPT="$SCOPE_DIR/scripts/no_op"
}

@test "Should log that there is nothing to do and succeed" {
	export SERVICE_ACTION="delete-scope"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📋 Nothing to do for delete-scope: the scope owns no cloud resources (distributed releases stay in the distribution console)"
	assert_line "✨ Done"
}

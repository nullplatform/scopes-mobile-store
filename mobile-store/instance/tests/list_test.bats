#!/usr/bin/env bats
# =============================================================================
# Unit tests for mobile-store/instance/scripts/{reserve_stdout,list}
#
# The instance workflow answers on stdout with JSON only. Every step is
# sourced in the same shell, so the first step keeps the real stdout on fd 3
# and sends everything else to stderr; the last step writes the answer of
# deployment/distribution/<layer>/list_releases to fd 3.
#
# Run: bats mobile-store/instance/tests/list_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SCOPE_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	source "$PROJECT_ROOT/testing/assertions.sh"
	source "$SCOPE_DIR/deployment/tests/helpers.bash"
	RESERVE="$SCOPE_DIR/instance/scripts/reserve_stdout"
	LIST="$SCOPE_DIR/instance/scripts/list"

	TEST_TMP_DIR=$(mktemp -d)
	export SERVICE_PATH="$TEST_TMP_DIR/service"
	mkdir -p "$SERVICE_PATH/deployment/distribution/fake"
	cat > "$SERVICE_PATH/deployment/distribution/fake/list_releases" <<'SCRIPT'
#!/bin/bash
echo "listing releases" >&2
echo '{"results":[{"platform":"android","version":"1.0.0"}]}'
SCRIPT
	chmod +x "$SERVICE_PATH/deployment/distribution/fake/list_releases"
	export DISTRIBUTION_LAYER="fake"
}

teardown() {
	rm -rf "$TEST_TMP_DIR"
}

@test "Should send the logs of every step to stderr and only the JSON answer to stdout" {
	run bash -c 'exec 2>/dev/null; source "$0"; echo "a step log"; source "$1"' "$RESERVE" "$LIST"

	assert_equal "$status" "0"
	assert_equal "$output" '{"results":[{"platform":"android","version":"1.0.0"}]}'
}

@test "Should print the answer on stdout when run on its own" {
	run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "0"
	assert_equal "$output" '{"results":[{"platform":"android","version":"1.0.0"}]}'
}

@test "Should answer no instances when the distribution layer cannot list releases" {
	export DISTRIBUTION_LAYER="google-play"

	run bash -c 'exec 2>"$1"; source "$0"' "$LIST" "$TEST_TMP_DIR/stderr"

	assert_equal "$status" "0"
	assert_equal "$output" '{"results":[]}'
	assert_equal "$(cat "$TEST_TMP_DIR/stderr")" "   ⚠️ The distribution layer 'google-play' cannot list releases; answering no instances"
}

@test "Should propagate a list_releases failure with its JSON answer" {
	printf '#!/bin/bash\necho "{\\"results\\": []}"\nexit 1\n' > "$SERVICE_PATH/deployment/distribution/fake/list_releases"

	run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "1"
	assert_equal "$output" '{"results": []}'
}

@test "Should remove the workdir of its own run and leave a concurrent run's alone" {
	export WORKDIR_BASE="$TEST_TMP_DIR/work"
	local run_a="$WORKDIR_BASE/scope-7-aaaaaa" run_b="$WORKDIR_BASE/scope-7-bbbbbb"
	mkdir -p "$run_a" "$run_b"
	echo '{}' > "$run_a/firebase-sa.json"
	echo '{}' > "$run_b/firebase-sa.json"

	WORKDIR="$run_a" run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "0"
	[ ! -d "$run_a" ]
	assert_file_exists "$run_b/firebase-sa.json"
}

@test "Should remove its workdir when list_releases fails too" {
	export WORKDIR_BASE="$TEST_TMP_DIR/work"
	mkdir -p "$WORKDIR_BASE/scope-7-cccccc"
	printf '#!/bin/bash\nexit 1\n' > "$SERVICE_PATH/deployment/distribution/fake/list_releases"

	WORKDIR="$WORKDIR_BASE/scope-7-cccccc" run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "1"
	[ ! -d "$WORKDIR_BASE/scope-7-cccccc" ]
}

@test "Should never remove a deployment workdir" {
	export WORKDIR_BASE="$TEST_TMP_DIR/work"
	mkdir -p "$WORKDIR_BASE/77"

	WORKDIR="$WORKDIR_BASE/77" run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "0"
	assert_directory_exists "$WORKDIR_BASE/77"
}

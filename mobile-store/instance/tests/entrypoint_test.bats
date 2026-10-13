#!/usr/bin/env bats
# =============================================================================
# Unit tests for the instance:data routing of the root entrypoint and
# service/instance/entrypoint.
#
# instance:data runs mobile-store/instance/workflows/list.yaml with
# np service workflow exec --no-output --build-context, after copying the
# scope id of the request into .notification.parameters.scope_id (what
# build-context reads). stdout must be the JSON answer only. np is a mock
# that records its arguments and the context it received.
#
# Run: bats mobile-store/instance/tests/entrypoint_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SCOPE_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	source "$PROJECT_ROOT/testing/assertions.sh"
	source "$SCOPE_DIR/deployment/tests/helpers.bash"
	ENTRYPOINT="$PROJECT_ROOT/entrypoint"

	TEST_TMP_DIR=$(mktemp -d)
	mkdir -p "$TEST_TMP_DIR/bin"
	cat > "$TEST_TMP_DIR/bin/np" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$NP_MOCK_CALLS_LOG"
printf '%s\n' "$NP_ACTION_CONTEXT" > "$NP_MOCK_CONTEXT_FILE"
echo "workflow logs go to stderr" >&2
echo '{"results":[{"platform":"android","release":"projects/1/apps/a/releases/r"}]}'
MOCK
	chmod +x "$TEST_TMP_DIR/bin/np"
	export PATH="$TEST_TMP_DIR/bin:$PATH"
	export NP_MOCK_CALLS_LOG="$TEST_TMP_DIR/np_calls.log"
	export NP_MOCK_CONTEXT_FILE="$TEST_TMP_DIR/context.json"
	unset NULLPLATFORM_API_KEY NP_API_KEY
}

teardown() {
	rm -rf "$TEST_TMP_DIR"
}

# notification <action> <arguments json>
notification() {
	jq -nc --arg action "$1" --argjson arguments "$2" \
		'{notification: {action: $action, arguments: $arguments, tags: {}, parameters: {}}}'
}

run_entrypoint() {
	run bash -c '"$0" "$@" 2>/dev/null' "$ENTRYPOINT" "$@"
}

@test "Should run the instance list workflow for instance:data and print only its JSON" {
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "instance:data" '{"scope_id": ["7"], "application_id": ["442353687"]}')

	run_entrypoint --service-path="$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "$output" '{"results":[{"platform":"android","release":"projects/1/apps/a/releases/r"}]}'
	assert_mock_call "$NP_MOCK_CALLS_LOG" "service workflow exec --no-output --build-context --no-params --workflow $SCOPE_DIR/instance/workflows/list.yaml"
	assert_equal "$(jq -r '.notification.parameters.scope_id' "$NP_MOCK_CONTEXT_FILE")" "7"
}

@test "Should accept a scalar scope id" {
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "instance:data" '{"scope_id": 7}')

	run_entrypoint --service-path="$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "$(jq -r '.notification.parameters.scope_id' "$NP_MOCK_CONTEXT_FILE")" "7"
}

@test "Should layer the instance workflow of an override directory" {
	mkdir -p "$TEST_TMP_DIR/overrides/instance/workflows"
	: > "$TEST_TMP_DIR/overrides/instance/workflows/list.yaml"
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "instance:data" '{"scope_id": ["7"]}')

	run_entrypoint --service-path="$SCOPE_DIR" --overrides-path="$TEST_TMP_DIR/overrides"

	assert_equal "$status" "0"
	assert_mock_call "$NP_MOCK_CALLS_LOG" "service workflow exec --no-output --build-context --no-params --workflow $SCOPE_DIR/instance/workflows/list.yaml --overrides $TEST_TMP_DIR/overrides/instance/workflows/list.yaml"
}

@test "Should answer no instances without calling np when the request has no scope id" {
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "instance:data" '{"application_id": ["442353687"]}')

	run_entrypoint --service-path="$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "$output" '{"results":[]}'
	[ ! -f "$NP_MOCK_CALLS_LOG" ]
}

@test "Should keep answering empty results for log:read and metric:list" {
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "log:read" '{"scope_id": ["7"]}')
	run_entrypoint --service-path="$SCOPE_DIR"
	assert_equal "$output" '{"results":[],"next_page_token":""}'

	NP_ACTION_CONTEXT=$(notification "metric:list" '{"scope_id": ["7"]}')
	run_entrypoint --service-path="$SCOPE_DIR"
	assert_equal "$output" '{"results":[]}'
	[ ! -f "$NP_MOCK_CALLS_LOG" ]
}

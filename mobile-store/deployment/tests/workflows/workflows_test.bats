#!/usr/bin/env bats
# =============================================================================
# Static tests of the workflows (deployment, scope, instance) and of the
# action routing of service/{scope,deployment}/entrypoint.
#
# The checks live in workflow_lint.py (python3 + PyYAML): every step file
# exists, every variable a step consumes is declared in the output of an
# earlier step, and the consumer table is honest. The routing tests run the
# real handlers with an np mock that records the workflow it was given.
#
# Run: bats mobile-store/deployment/tests/workflows/workflows_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	SCOPE_DIR="$(cd "$DEPLOYMENT_DIR/.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	source "$PROJECT_ROOT/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	LINT="$TEST_DIR/workflow_lint.py"

	if ! python3 -c 'import yaml' 2>/dev/null; then
		skip "python3 with PyYAML is required for the workflow checks"
	fi
	export PYTHONDONTWRITEBYTECODE=1
	TEST_TMP_DIR=$(mktemp -d)
}

teardown() {
	rm -rf "${TEST_TMP_DIR:-}"
}

all_workflows() {
	find "$SCOPE_DIR" -path '*/workflows/*.yaml' -not -path '*/tests/*' | sort
}

lint() {
	run python3 "$LINT" "$SCOPE_DIR" "$@"
}

@test "Should have every workflow the README routes to" {
	for workflow in deployment/workflows/{initial,blue_green,switch_traffic,finalize,rollback,delete}.yaml \
		scope/workflows/{create,update,delete}.yaml instance/workflows/list.yaml; do
		assert_file_exists "$SCOPE_DIR/$workflow"
	done
}

@test "Should parse every workflow and run only files that exist" {
	# shellcheck disable=SC2046
	lint files $(all_workflows)

	assert_equal "$output" ""
	assert_equal "$status" "0"
}

@test "Should declare every consumed variable in the output of an earlier step" {
	# shellcheck disable=SC2046
	lint outputs $(all_workflows)

	assert_equal "$output" ""
	assert_equal "$status" "0"
}

@test "Should keep the consumer table in sync with the scripts" {
	lint consumes

	assert_equal "$output" ""
	assert_equal "$status" "0"
}

@test "Should catch a variable that is no longer declared as an output" {
	mkdir -p "$TEST_TMP_DIR/deployment/workflows"
	python3 -c '
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
for step in workflow["steps"]:
    if step["name"] == "setup gate layer":
        del step["output"]
    if step["name"] == "assume role":
        step["output"] = [o for o in step["output"] if o["name"] != "AWS_SESSION_TOKEN"]
workflow["include"] = []
yaml.safe_dump(workflow, open(sys.argv[2], "w"))
' "$SCOPE_DIR/deployment/workflows/initial.yaml" "$TEST_TMP_DIR/initial.yaml"

	lint outputs "$TEST_TMP_DIR/initial.yaml"

	assert_equal "$status" "1"
	assert_line "$TEST_TMP_DIR/initial.yaml: step 'publish' consumes GATE_RESULT, which no earlier step declares in its output"
	assert_line "$TEST_TMP_DIR/initial.yaml: step 'platform layers' consumes AWS_SESSION_TOKEN, which no earlier step declares in its output"
}

@test "Should run the rollout check first in blue_green and then every step of initial" {
	run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import workflow_lint
steps, _ = workflow_lint.load(sys.argv[2] + "/deployment/workflows/blue_green.yaml", sys.argv[2])
print(",".join(s["name"] for s in steps))
' "$TEST_DIR" "$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "$output" "check active rollout,assume role,build context,platform layers,setup signing layer,setup distribution layer,setup gate layer,publish"
}

@test "Should run the scope context and the layer checks on create and update" {
	for action in create update; do
		run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import workflow_lint
steps, _ = workflow_lint.load(sys.argv[2], sys.argv[3])
print(",".join("%s:%s" % (s["name"], (s.get("configuration") or {}).get("LAYER_CHECK", (s.get("configuration") or {}).get("BUILD_CONTEXT_MODE", ""))) for s in steps))
' "$TEST_DIR" "$SCOPE_DIR/scope/workflows/$action.yaml" "$SCOPE_DIR"

		assert_equal "$output" "assume role:,build context:scope,check signing layer:true,check distribution layer:true,check gate layer:true"
	done
}

# =============================================================================
# Routing: every action of specs/actions reaches an existing workflow
# =============================================================================
@test "Should route every action spec to an existing workflow" {
	mkdir -p "$TEST_TMP_DIR/bin"
	cat > "$TEST_TMP_DIR/bin/np" <<'MOCK'
#!/bin/bash
while [ $# -gt 0 ]; do
	if [ "$1" = "--workflow" ]; then echo "$2" > "$NP_MOCK_WORKFLOW_FILE"; fi
	shift
done
MOCK
	chmod +x "$TEST_TMP_DIR/bin/np"
	export PATH="$TEST_TMP_DIR/bin:$PATH"
	export NP_MOCK_WORKFLOW_FILE="$TEST_TMP_DIR/workflow"
	export WORKING_DIRECTORY="$PROJECT_ROOT" SERVICE_PATH="$SCOPE_DIR" OVERRIDES_PATH="" SCOPE_ID=7

	local spec slug type handler routed=0
	for spec in "$SCOPE_DIR"/specs/actions/*.json.tpl; do
		slug=$(sed -nE 's/^  "slug": "([^"]+)".*/\1/p' "$spec")
		type=$(sed -nE 's/^  "type": "([^"]+)".*/\1/p' "$spec")
		handler="scope"
		export DEPLOYMENT_ID=""
		if grep -q '"deployment_id"' "$spec"; then
			handler="deployment"
			DEPLOYMENT_ID=77
		fi
		rm -f "$NP_MOCK_WORKFLOW_FILE"

		SERVICE_ACTION="$slug" SERVICE_ACTION_TYPE="$type" run bash "$PROJECT_ROOT/service/$handler/entrypoint"

		if [ "$status" != "0" ] || [ ! -f "$NP_MOCK_WORKFLOW_FILE" ] || [ ! -f "$(cat "$NP_MOCK_WORKFLOW_FILE")" ]; then
			echo "$slug ($type, $handler) is not routed to an existing workflow: ${output}"
			return 1
		fi
		routed=$((routed + 1))
	done
	assert_equal "$routed" "9"
}

@test "Should keep instance:data read-only: no publish, rollback or gate, only the distribution setup and list_releases" {
	run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import workflow_lint
steps, _ = workflow_lint.load(sys.argv[2] + "/instance/workflows/list.yaml", sys.argv[2])
for s in steps:
    c = s.get("configuration") or {}
    print("%s|%s|%s" % (s["file"].split("/")[-1], c.get("LAYER_TYPE", ""), c.get("LAYER_CHECK", "")))
' "$TEST_DIR" "$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "$output" "reserve_stdout||
assume_role_step||
build_context||
layer_executor|distribution|
list||"
	# The only distribution scripts the instance steps can run are setup (layer_executor) and list_releases.
	run grep -hoE 'distribution/[^"]*/(publish|rollback|distribute)|do_publish|do_rollback|gate/' \
		"$SCOPE_DIR/instance/scripts/list" "$SCOPE_DIR/instance/scripts/reserve_stdout"
	assert_equal "$output" ""
	grep -q 'list_releases' "$SCOPE_DIR/instance/scripts/list"
}

@test "Should run build_context in rollback mode for rollbacks and with distribution-only requirements for instances" {
	run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import workflow_lint
for path in ("deployment/workflows/rollback.yaml", "instance/workflows/list.yaml"):
    steps, _ = workflow_lint.load(sys.argv[2] + "/" + path, sys.argv[2])
    c = [s for s in steps if s["name"] == "build context"][0].get("configuration") or {}
    print("%s %s %s" % (path, c.get("BUILD_CONTEXT_MODE", ""), c.get("BUILD_CONTEXT_REQUIRE", "all")))
' "$TEST_DIR" "$SCOPE_DIR"

	assert_equal "$output" "deployment/workflows/rollback.yaml rollback all
instance/workflows/list.yaml scope distribution"
}

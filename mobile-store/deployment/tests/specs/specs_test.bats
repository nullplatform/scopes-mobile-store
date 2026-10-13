#!/usr/bin/env bats
# =============================================================================
# Spec templates: every specs/**/*.json.tpl renders with gomplate into valid
# JSON and carries the scope's identity.
#
# Run: bats mobile-store/deployment/tests/specs/specs_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	MODULE_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	PROJECT_ROOT="$(cd "$MODULE_DIR/.." && pwd)"
	SPECS_DIR="$MODULE_DIR/specs"
	source "$PROJECT_ROOT/testing/assertions.sh"

	command -v gomplate >/dev/null || skip "gomplate is not installed"

	export NRN="organization=1:account=2"
	export SERVICE_SPECIFICATION_ID="spec_test"
	export NP_API_KEY="test-key"
	export REPO_PATH="/app/pkg"
	export SERVICE_PATH="mobile-store"
	export ENVIRONMENT="test"
	export SERVICE_SLUG="mobile-store"
}

render() {
	gomplate -f "$1"
}

@test "Every spec template renders into valid JSON" {
	local count=0
	for tpl in "$SPECS_DIR"/*.json.tpl "$SPECS_DIR"/actions/*.json.tpl; do
		run bash -c "gomplate -f '$tpl' | jq -e . >/dev/null"
		[ "$status" -eq 0 ] || { echo "invalid JSON: $tpl"; echo "$output"; return 1; }
		count=$((count + 1))
	done
	local expected
	expected=$(( $(find "$SPECS_DIR" -maxdepth 1 -name "*.json.tpl" | wc -l) + $(find "$SPECS_DIR/actions" -name "*.json.tpl" | wc -l) ))
	assert_greater_than "$count" "0" "spec templates"
	assert_equal "$count" "$expected"
}

@test "Service spec declares the Mobile store identity and every action it lists has a template" {
	local spec
	spec=$(render "$SPECS_DIR/service-spec.json.tpl")
	assert_equal "$(echo "$spec" | jq -r .name)" "Mobile store"
	assert_equal "$(echo "$spec" | jq -r .selectors.sub_category)" "Mobile store"
	assert_equal "$(echo "$spec" | jq -r .type)" "scope"
	assert_greater_than "$(echo "$spec" | jq '.available_actions | length')" "0" "available_actions"
	for action in $(echo "$spec" | jq -r '.available_actions[]'); do
		assert_file_exists "$SPECS_DIR/actions/$action.json.tpl"
		assert_equal "$(render "$SPECS_DIR/actions/$action.json.tpl" | jq -r .slug)" "$action"
	done
}

@test "Every action template is listed in available_actions (no orphan templates)" {
	local spec tpl slug
	spec=$(render "$SPECS_DIR/service-spec.json.tpl")
	for tpl in "$SPECS_DIR"/actions/*.json.tpl; do
		slug=$(basename "$tpl" .json.tpl)
		assert_equal "$(echo "$spec" | jq -r --arg s "$slug" '.available_actions | index($s) != null')" "true"
	done
}

@test "Scope type and notification channel point at the service specification" {
	assert_equal "$(render "$SPECS_DIR/scope-type-definition.json.tpl" | jq -r .provider_id)" "spec_test"
	assert_equal "$(render "$SPECS_DIR/scope-type-definition.json.tpl" | jq -r .name)" "Mobile store"
	assert_equal "$(render "$SPECS_DIR/notification-channel.json.tpl" | jq -r '.filters["$or"][1]["arguments.scope_provider"]')" "spec_test"
	assert_equal "$(render "$SPECS_DIR/notification-channel.json.tpl" | jq -r '.configuration.command.data.cmdline')" "/app/pkg/entrypoint --service-path=/app/pkg/mobile-store"
}

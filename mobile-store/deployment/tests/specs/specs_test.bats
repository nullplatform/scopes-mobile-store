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

@test "Service spec exposes platform, channel and rollout percentage in developer vocabulary" {
	local schema
	schema=$(render "$SPECS_DIR/service-spec.json.tpl" | jq .attributes.schema)
	assert_equal "$(echo "$schema" | jq -c .required)" '["platform","channel"]'
	assert_equal "$(echo "$schema" | jq -r '.properties.platform.oneOf | map(.const) | join(",")')" "android,ios,both"
	assert_equal "$(echo "$schema" | jq -r .properties.platform.default)" "android"
	assert_equal "$(echo "$schema" | jq -c .properties.platform.editableOn)" '["create"]'
	assert_equal "$(echo "$schema" | jq -r '.properties.channel.oneOf | map(.const) | join(",")')" "internal,testers,production"
	assert_equal "$(echo "$schema" | jq -r .properties.channel.default)" "internal"
	assert_equal "$(echo "$schema" | jq -c .properties.channel.editableOn)" '["create","update"]'
	assert_equal "$(echo "$schema" | jq -r .properties.rollout_percentage.type)" "integer"
	assert_equal "$(echo "$schema" | jq -r .properties.rollout_percentage.minimum)" "1"
	assert_equal "$(echo "$schema" | jq -r .properties.rollout_percentage.maximum)" "100"
	assert_equal "$(echo "$schema" | jq -r .properties.rollout_percentage.default)" "5"
	assert_equal "$(echo "$schema" | jq -c .properties.rollout_percentage.editableOn)" '["create","update"]'
	assert_equal "$(echo "$schema" | jq -r '.uiSchema.elements | map(.scope) | join(",")')" "#/properties/platform,#/properties/channel,#/properties/rollout_percentage"
	assert_equal "$(echo "$schema" | jq -r '[.properties[] | .title, .description] | map(test("firebase|apple|google|fastlane"; "i")) | any')" "false"
}

@test "Scope configuration declares the layers and the assets bucket for DevOps" {
	local cfg
	cfg=$(render "$SPECS_DIR/scope-configuration.json.tpl")
	assert_equal "$(echo "$cfg" | jq -r .name)" "Mobile store"
	assert_equal "$(echo "$cfg" | jq -r .category)" "scope-configurations"
	assert_true "$(echo "$cfg" | jq -r .allow_dimensions)" "allow_dimensions"
	assert_equal "$(echo "$cfg" | jq -r '.visible_to[0]')" "organization=1:account=2"
	assert_equal "$(echo "$cfg" | jq -r '.schema.properties.platform_layer.oneOf | map(.const) | join(",")')" "android,ios"
	assert_equal "$(echo "$cfg" | jq -r '.schema.properties.signing_layer.oneOf | map(.const) | join(",")')" "prebuilt,keyvault,match"
	assert_equal "$(echo "$cfg" | jq -r '.schema.properties.distribution_layer.oneOf | map(.const) | join(",")')" "firebase,app-store,google-play,foundry-eas,intune"
	assert_equal "$(echo "$cfg" | jq -r '.schema.properties.gate_layer.oneOf | map(.const) | join(",")')" "none,store-review"
	assert_equal "$(echo "$cfg" | jq -c .schema.required)" '["platform_layer","signing_layer","distribution_layer","gate_layer","assets"]'
	assert_equal "$(echo "$cfg" | jq -c .schema.properties.assets.required)" '["bucket"]'
	assert_equal "$(echo "$cfg" | jq -r .schema.properties.assets.properties.region.default)" "us-east-1"
	assert_equal "$(echo "$cfg" | jq -r '.schema.allOf[] | select(.if.properties.distribution_layer.const == "firebase") | .then.required[0]')" "firebase"
	assert_equal "$(echo "$cfg" | jq -r '.schema.allOf[] | select(.if.properties.signing_layer.const == "keyvault") | .then.properties.android.required[0]')" "keystore_secret"
}

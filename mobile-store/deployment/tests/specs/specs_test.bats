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
	assert_equal "$(echo "$spec" | jq -c '.attributes.schema.properties.asset_type | {type, default, export}')" '{"type":"string","default":"bundle","export":false}'
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

# Every uiSchema scope (controls and rule conditions) must resolve to a schema property:
# "#/properties/a/properties/b" -> getpath(["properties","a","properties","b"]).
assert_ui_scopes_resolve() {
	local schema="$1" uischema="$2" scope
	for scope in $(echo "$uischema" | jq -r '[.. | objects | (.scope? // empty), (.condition?.scope? // empty)] | unique[]'); do
		[ "$scope" = "#" ] && continue
		assert_true "$(echo "$schema" | jq -r --arg s "$scope" '($s | ltrimstr("#/") | split("/")) as $p | getpath($p) != null')" "uiSchema scope $scope resolves to a schema property"
	done
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
	assert_equal "$(echo "$schema" | jq -r '.uiSchema.type')" "VerticalLayout"
	assert_equal "$(echo "$schema" | jq -c '.uiSchema.elements | map(.scope)')" '["#/properties/platform","#/properties/channel","#/properties/rollout_percentage"]'
	assert_equal "$(echo "$schema" | jq -r '[.properties | .. | (.title?, .description?) | strings] | map(test("firebase|apple|google|fastlane"; "i")) | any')" "false"
}

@test "Scope configuration declares the layers and the assets bucket for DevOps" {
	local cfg
	cfg=$(render "$SPECS_DIR/scope-configuration.json.tpl")
	assert_equal "$(echo "$cfg" | jq -r .name)" "Mobile store"
	assert_equal "$(echo "$cfg" | jq -r .category)" "scope-configurations"
	assert_true "$(echo "$cfg" | jq -r .allow_dimensions)" "allow_dimensions"
	assert_equal "$(echo "$cfg" | jq -r '.visible_to[0]')" "organization=1:account=2"
	assert_equal "$(echo "$cfg" | jq -r '.schema.properties | has("platform_layer")')" "false"
	assert_equal "$(echo "$cfg" | jq -r '.schema.properties.signing_layer.oneOf | map(.const) | join(",")')" "prebuilt,keyvault,match"
	assert_equal "$(echo "$cfg" | jq -r .schema.properties.signing_layer.default)" "prebuilt"
	assert_equal "$(echo "$cfg" | jq -r '.schema.properties.distribution_layer.oneOf | map(.const) | join(",")')" "firebase,app-store,google-play,foundry-eas,intune"
	assert_equal "$(echo "$cfg" | jq -r .schema.properties.distribution_layer.default)" "firebase"
	assert_equal "$(echo "$cfg" | jq -r '.schema.properties.gate_layer.oneOf | map(.const) | join(",")')" "none,store-review"
	assert_equal "$(echo "$cfg" | jq -r .schema.properties.gate_layer.default)" "none"
	assert_equal "$(echo "$cfg" | jq -c .schema.required)" '["signing_layer","distribution_layer","gate_layer","assets"]'
	assert_equal "$(echo "$cfg" | jq -c .schema.properties.assets.required)" '["bucket"]'
	assert_equal "$(echo "$cfg" | jq -r .schema.properties.assets.properties.region.default)" "us-east-1"
	assert_equal "$(echo "$cfg" | jq -c '.schema.properties | [.firebase, .android, .ios] | map(.type)')" '["object","object","object"]'
	assert_equal "$(echo "$cfg" | jq -c '.schema.properties.firebase.properties | keys')" '["app_id_android","app_id_ios","credentials_secret","project"]'
	assert_equal "$(echo "$cfg" | jq -c '.schema.properties.android.properties | keys')" '["keystore_secret","package"]'
	assert_equal "$(echo "$cfg" | jq -c '.schema.properties.ios.properties | keys')" '["app_store_connect_key_secret","bundle_id"]'
}

@test "Scope configuration conditionally requires firebase and keystore settings" {
	local schema
	schema=$(render "$SPECS_DIR/scope-configuration.json.tpl" | jq .schema)
	assert_equal "$(echo "$schema" | jq -r '.allOf | length')" "2"
	assert_equal "$(echo "$schema" | jq -c '.allOf[0].if.required')" '["distribution_layer"]'
	assert_equal "$(echo "$schema" | jq -c '.allOf[0].if.properties.distribution_layer.const')" '"firebase"'
	assert_equal "$(echo "$schema" | jq -c '.allOf[0].then.required')" '["firebase"]'
	assert_equal "$(echo "$schema" | jq -c '.allOf[0].then.properties.firebase.required')" '["project","credentials_secret"]'
	assert_equal "$(echo "$schema" | jq -c '.allOf[1].if.required')" '["signing_layer"]'
	assert_equal "$(echo "$schema" | jq -c '.allOf[1].if.properties.signing_layer.const')" '"keyvault"'
	assert_equal "$(echo "$schema" | jq -c '.allOf[1].then.required')" '["android"]'
	assert_equal "$(echo "$schema" | jq -c '.allOf[1].then.properties.android.required')" '["keystore_secret"]'
}

@test "Every uiSchema scope of both specs resolves to an existing schema property" {
	local schema
	schema=$(render "$SPECS_DIR/service-spec.json.tpl" | jq .attributes.schema)
	assert_greater_than "$(echo "$schema" | jq '[.uiSchema | .. | objects | .scope? // empty] | length')" "0" "service spec uiSchema scopes"
	assert_ui_scopes_resolve "$schema" "$(echo "$schema" | jq .uiSchema)"
	schema=$(render "$SPECS_DIR/scope-configuration.json.tpl" | jq .schema)
	assert_greater_than "$(echo "$schema" | jq '[.uiSchema | .. | objects | .scope? // empty] | length')" "0" "scope configuration uiSchema scopes"
	assert_ui_scopes_resolve "$schema" "$(echo "$schema" | jq .uiSchema)"
}

@test "Spec descriptions fit the platform limits" {
	# The provider specification API answers 500 to long descriptions (seen with 285 characters)
	local spec
	for tpl in "$SPECS_DIR/scope-configuration.json.tpl" "$SPECS_DIR/service-spec.json.tpl" "$SPECS_DIR/scope-type-definition.json.tpl"; do
		spec=$(render "$tpl")
		assert_less_than "$(echo "$spec" | jq -r '.description // "" | length')" "121" "description of $(basename "$tpl")"
	done
}

#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/build_context
#
# The script reads CONTEXT (the deployment context JSON) and exports the
# variables every later step of the deployment workflows relies on. The np CLI
# is replaced by tests/resources/mocks/np, which answers with the JSON files
# named by NP_MOCK_* variables (see the mock header).
#
# Run: bats mobile-store/deployment/tests/scripts/build_context_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	SCOPE_DIR="$(cd "$DEPLOYMENT_DIR/.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	RESOURCES_DIR="$DEPLOYMENT_DIR/tests/resources"
	MOCKS_DIR="$RESOURCES_DIR/mocks"
	SCRIPT="$DEPLOYMENT_DIR/scripts/build_context"

	source "$PROJECT_ROOT/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"

	TEST_TMP_DIR=$(mktemp -d)
	export SERVICE_PATH="$SCOPE_DIR"
	export CONTEXT
	CONTEXT=$(cat "$RESOURCES_DIR/context_initial.json")
	export WORKDIR="$TEST_TMP_DIR/work"

	export PATH="$MOCKS_DIR:$PATH"
	export NP_MOCK_CALLS_LOG="$TEST_TMP_DIR/np_calls.log"
	export NP_MOCK_SPECIFICATION_LIST="$MOCKS_DIR/scope_configuration/specification_list.json"
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list.json"
	export NP_MOCK_ASSET_LIST="$MOCKS_DIR/asset_list.json"
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list.json"
	export NP_MOCK_RELEASE_READ="$MOCKS_DIR/release_read.json"

	unset SIGNING_LAYER DISTRIBUTION_LAYER GATE_LAYER ASSETS_BUCKET ASSETS_REGION
}

teardown() {
	rm -rf "$TEST_TMP_DIR"
}

run_build_context() {
	source "$SCRIPT"
}

with_context() {
	CONTEXT=$(echo "$CONTEXT" | jq "$1")
	export CONTEXT
}

# =============================================================================
# Happy path: every variable the later steps rely on
# =============================================================================
@test "Should export the full deployment context for an android scope in uat" {
	run_build_context

	assert_equal "$DIMENSION" "uat"
	assert_equal "$PLATFORMS" "android"
	assert_equal "$CHANNEL" "internal"
	assert_equal "$ROLLOUT_PERCENTAGE" "5"
	assert_equal "$RELEASE_SEMVER" "1.0.0"
	assert_equal "$DEPLOYMENT_ID" "77"
	assert_equal "$SCOPE_ID" "7"
	assert_equal "$APPLICATION_SLUG" "sample"
	assert_equal "$NAMESPACE_SLUG" "mobile"
	assert_equal "$SCOPE_SLUG" "store"
	assert_equal "$ASSET_TYPE" "bundle"

	assert_equal "$SIGNING_LAYER" "prebuilt"
	assert_equal "$DISTRIBUTION_LAYER" "firebase"
	assert_equal "$GATE_LAYER" "none"
	assert_equal "$ASSETS_BUCKET" "assets-aws-mobile"
	assert_equal "$ASSETS_REGION" "us-east-1"

	local expected_assets='{
	"android": {
		"url": "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk",
		"asset_id": 6,
		"build_id": 10
	}
	}'
	assert_json_equal "$ASSETS_JSON" "$expected_assets" "ASSETS_JSON"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
	assert_equal "$ASSET_VERSION" "1.0.0"
	assert_equal "$ASSET_BUILD_NUMBER" "10"
	assert_equal "$ANDROID_PACKAGE" "ar.io.nullplatform.sample"
	assert_empty "$IOS_BUNDLE_ID" "IOS_BUNDLE_ID"

	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "70"
	assert_equal "$PREVIOUS_RELEASE_SEMVER" "0.9.0"

	assert_equal "$WORKDIR" "$TEST_TMP_DIR/work/77"
	assert_directory_exists "$WORKDIR"

	# The asset in the context already matches android-uat: no listing needed.
	refute_np_called "asset list"
}

@test "Should print a readable summary without dumping the scope configuration" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Building deployment context..."
	assert_line "   📋 Scope: mobile/sample/store (id 7) | Dimension: uat | Deployment: 77 | Release: 1.0.0"
	assert_line "   📋 Platforms: android | Channel: internal | Rollout: 5%"
	assert_line "   📋 Scope configuration: resolved from the platform (nrn organization=1:account=2:namespace=3)"
	assert_line "   ✅ signing_layer=prebuilt"
	assert_line "   ✅ distribution_layer=firebase"
	assert_line "   ✅ gate_layer=none"
	assert_line "   ✅ assets_bucket=assets-aws-mobile (region us-east-1)"
	assert_line "📡 Resolving build assets (type bundle, build 10)..."
	assert_line "   ✅ android: android-uat -> s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk (release 1.0.0, build 10)"
	assert_line "   📋 Previous deployment: 70 (release 0.9.0)"
	assert_line "   📋 Workdir: $TEST_TMP_DIR/work/77"
	assert_line "✨ Build context ready"
	# Secret names stay out of the log.
	refute_line "mobile/firebase-sa"
	if [[ "$output" == *"credentials_secret"* ]]; then
		echo "the scope configuration was dumped to the log"
		return 1
	fi
}

# =============================================================================
# Platforms and assets
# =============================================================================
@test "Should resolve both platforms from the build assets when platform is both" {
	with_context '.scope.capabilities.platform = "both"'
	export NP_MOCK_ASSET_LIST="$MOCKS_DIR/asset_list_both.json"

	run_build_context

	assert_equal "$PLATFORMS" "android ios"
	local expected_assets='{
	"android": {
		"url": "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk",
		"asset_id": 6,
		"build_id": 10
	},
	"ios": {
		"url": "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.ipa",
		"asset_id": 12,
		"build_id": 10
	}
	}'
	assert_json_equal "$ASSETS_JSON" "$expected_assets" "ASSETS_JSON"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
	assert_np_called "np asset list --build-id 10 --format json"
}

@test "Should fail with the full troubleshooting block when the ios binary is missing for platform both" {
	with_context '.scope.capabilities.platform = "both"'
	# asset_list.json only has an ios-uat of another type: it must not be picked.

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ No asset named 'ios-uat' of type 'bundle' in release 1.0.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI did not build a binary for the 'uat' environment"
	assert_line "    • The asset was registered with another name"
	assert_line "  🔧 How to fix:"
	assert_line "    • Make the CI register an asset named 'ios-uat' (type bundle) for this build"
}

@test "Should pick the asset by name for the prod dimension even when the context carries android-uat" {
	with_context '.scope.dimensions.environment = "prod"'

	run_build_context

	assert_equal "$DIMENSION" "prod"
	local expected_assets='{
	"android": {
		"url": "s3://assets-aws-mobile/mobile/442353687/10/prod/app-release.apk",
		"asset_id": 8,
		"build_id": 10
	}
	}'
	assert_json_equal "$ASSETS_JSON" "$expected_assets" "ASSETS_JSON"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/prod/app-release.apk"
	assert_np_called "np asset list --build-id 10 --format json"
}

@test "Should fail with an actionable message when the build has no asset for the dimension" {
	with_context '.scope.dimensions.environment = "staging"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ No asset named 'android-staging' of type 'bundle' in release 1.0.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI did not build a binary for the 'staging' environment"
	assert_line "    • The asset was registered with another name"
	assert_line "  🔧 How to fix:"
	assert_line "    • Make the CI register an asset named 'android-staging' (type bundle) for this build"
}

@test "Should warn and still fail when the asset listing itself fails" {
	with_context '.scope.dimensions.environment = "prod"'
	unset NP_MOCK_ASSET_LIST

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ⚠️ Could not list the assets of build 10 (np asset list failed)"
	assert_line "   ❌ No asset named 'android-prod' of type 'bundle' in release 1.0.0"
}

@test "Should use the default dimension when the scope has no environment dimension" {
	with_context '.scope.dimensions = {} | .asset.name = "android-default"'

	run_build_context

	assert_equal "$DIMENSION" "default"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
}

@test "Should take the expected asset type from the asset of the context" {
	with_context '.asset.type = "mobile-binary" | .asset.name = "android-prod"'
	with_context '.scope.dimensions.environment = "prod"'
	# The listed android-prod is a bundle, so it must not match a mobile-binary scope.

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📡 Resolving build assets (type mobile-binary, build 10)..."
	assert_line "   ✅ android: android-prod -> s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk (release 1.0.0, build 10)"
}

@test "Should resolve the same context when the asset carries no metadata (the platform does not persist it)" {
	with_context '.asset.metadata = {}'

	run_build_context

	local expected_assets='{
	"android": {
		"url": "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk",
		"asset_id": 6,
		"build_id": 10
	}
	}'
	assert_json_equal "$ASSETS_JSON" "$expected_assets" "ASSETS_JSON"
	assert_equal "$ASSET_VERSION" "1.0.0"
	assert_equal "$ASSET_BUILD_NUMBER" "10"
	assert_equal "$ANDROID_PACKAGE" "ar.io.nullplatform.sample"
}

@test "Should export the app identifiers from the scope configuration" {
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"
	with_context '.providers["scope-configurations"].ios = {"bundle_id": "io.nullplatform.sample"}'

	run_build_context

	assert_equal "$ANDROID_PACKAGE" "ar.io.nullplatform.sample"
	assert_equal "$IOS_BUNDLE_ID" "io.nullplatform.sample"
}

@test "Should reject an unsupported platform" {
	with_context '.scope.capabilities.platform = "windows"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unsupported platform 'windows'"
	assert_line "  💡 Possible causes:"
	assert_line "    • The scope capability platform is not one of: android, ios, both"
	assert_line "  🔧 How to fix:"
	assert_line "    • Recreate the scope choosing Android, iOS or both (platform is only editable on create)"
}

# =============================================================================
# Channel and rollout percentage
# =============================================================================
@test "Should default channel to internal and rollout to 5 when the capabilities are missing" {
	with_context 'del(.scope.capabilities.channel) | del(.scope.capabilities.rollout_percentage)'

	run_build_context

	assert_equal "$CHANNEL" "internal"
	assert_equal "$ROLLOUT_PERCENTAGE" "5"
}

@test "Should export the channel and rollout chosen by the developer" {
	with_context '.scope.capabilities.channel = "testers" | .scope.capabilities.rollout_percentage = 25'

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 Platforms: android | Channel: testers | Rollout: 25%"
}

@test "Should reject an unsupported channel" {
	with_context '.scope.capabilities.channel = "vip"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unsupported channel 'vip'"
	assert_line "  💡 Possible causes:"
	assert_line "    • The scope capability channel is not one of: internal, testers, production"
	assert_line "  🔧 How to fix:"
	assert_line "    • Update the scope and choose one of the available distribution channels"
}

@test "Should reject a rollout_percentage outside 1..100 or not an integer" {
	local value
	for value in 0 101 '"abc"'; do
		CONTEXT=$(cat "$RESOURCES_DIR/context_initial.json" | jq ".scope.capabilities.rollout_percentage = $value")
		export CONTEXT
		local shown
		shown=$(echo "$value" | tr -d '"')

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ rollout_percentage must be an integer between 1 and 100, got '$shown'"
		assert_line "  💡 Possible causes:"
		assert_line "    • The scope was created or updated with an invalid rollout_percentage capability"
		assert_line "  🔧 How to fix:"
		assert_line "    • Update the scope and set rollout_percentage to a value between 1 and 100"
	done
}

# =============================================================================
# Scope configuration resolution: platform > context > environment variables
# =============================================================================
@test "Should resolve the mobile-store configuration closest to the scope and put it back in the context" {
	run_build_context

	assert_equal "$(echo "$SCOPE_CONFIGURATION" | jq -r .marker)" "namespace-level"
	assert_equal "$(echo "$SCOPE_CONFIGURATION" | jq -r .firebase.project)" "np-mobile-poc"
	assert_equal "$(echo "$CONTEXT" | jq -r '.providers["scope-configurations"].marker')" "namespace-level"
	assert_np_called "np provider list --nrn organization=1:account=2:namespace=3:application=442353687:scope=7 --categories scope-configurations --show-ascendants --dimensions environment:uat --format json"
}

@test "Should fall back to the scope configuration of the context when the platform lookup finds nothing" {
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 Scope configuration: taken from the context"
	run_build_context
	assert_equal "$(echo "$SCOPE_CONFIGURATION" | jq -r .marker)" "from-context"
	assert_equal "$SIGNING_LAYER" "prebuilt"
	assert_equal "$ASSETS_BUCKET" "assets-aws-mobile"
}

@test "Should fall back to environment variables when there is no scope configuration at all" {
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"
	with_context 'del(.providers["scope-configurations"])'
	export SIGNING_LAYER="keyvault"
	export DISTRIBUTION_LAYER="google-play"
	export GATE_LAYER="store-review"
	export ASSETS_BUCKET="assets-from-env"

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   📋 Scope configuration: taken from environment variables"
	assert_line "   ✅ assets_bucket=assets-from-env (region us-east-1)"

	run_build_context
	assert_equal "$SIGNING_LAYER" "keyvault"
	assert_equal "$DISTRIBUTION_LAYER" "google-play"
	assert_equal "$GATE_LAYER" "store-review"
	assert_equal "$ASSETS_BUCKET" "assets-from-env"
	assert_equal "$ASSETS_REGION" "us-east-1"
	assert_empty "$ANDROID_PACKAGE" "ANDROID_PACKAGE"
	assert_empty "$IOS_BUNDLE_ID" "IOS_BUNDLE_ID"
	local expected_configuration='{
	"signing_layer": "keyvault",
	"distribution_layer": "google-play",
	"gate_layer": "store-review",
	"assets": { "bucket": "assets-from-env", "region": "us-east-1" }
	}'
	assert_json_equal "$SCOPE_CONFIGURATION" "$expected_configuration" "SCOPE_CONFIGURATION"
}

@test "Should fail with the full troubleshooting block when no scope configuration or env vars exist" {
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"
	with_context 'del(.providers["scope-configurations"])'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Scope configuration is incomplete: missing signing_layer, distribution_layer, gate_layer, assets.bucket"
	assert_line "  💡 Possible causes:"
	assert_line "    • No 'Mobile store' scope configuration is attached to the account, namespace or dimension of this scope"
	assert_line "    • The scope configuration does not set those fields"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create a 'Mobile store' scope configuration (category scope-configurations) for the account, namespace or dimension of this scope"
	assert_line "    • Or set the SIGNING_LAYER, DISTRIBUTION_LAYER, GATE_LAYER and ASSETS_BUCKET environment variables"
}

@test "Should report only the missing fields when the scope configuration is partial" {
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"
	with_context 'del(.providers["scope-configurations"].gate_layer) | del(.providers["scope-configurations"].assets)'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Scope configuration is incomplete: missing gate_layer, assets.bucket"
}

# =============================================================================
# Previous deployment
# =============================================================================
@test "Should leave the previous deployment empty when the scope was never deployed successfully" {
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list_no_previous.json"

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   📋 Previous deployment: none"

	run_build_context
	assert_empty "$PREVIOUS_DEPLOYMENT_ID" "PREVIOUS_DEPLOYMENT_ID"
	assert_empty "$PREVIOUS_RELEASE_SEMVER" "PREVIOUS_RELEASE_SEMVER"
}

@test "Should not fail when the deployment listing fails" {
	unset NP_MOCK_DEPLOYMENT_LIST

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not list the deployments of scope 7; continuing without a previous deployment"
	assert_line "   📋 Previous deployment: none"

	run_build_context
	assert_empty "$PREVIOUS_DEPLOYMENT_ID" "PREVIOUS_DEPLOYMENT_ID"
	assert_empty "$PREVIOUS_RELEASE_SEMVER" "PREVIOUS_RELEASE_SEMVER"
}

@test "Should keep the previous deployment id when its release cannot be read" {
	unset NP_MOCK_RELEASE_READ

	run_build_context

	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "70"
	assert_empty "$PREVIOUS_RELEASE_SEMVER" "PREVIOUS_RELEASE_SEMVER"
}

# =============================================================================
# Workdir and input validation
# =============================================================================
@test "Should default the workdir to /tmp/mobile-store/<deployment id>" {
	unset WORKDIR

	run_build_context

	assert_equal "$WORKDIR" "/tmp/mobile-store/77"
	assert_directory_exists "$WORKDIR"
	rm -rf "/tmp/mobile-store/77"
}

@test "Should fail when CONTEXT is missing or not JSON" {
	unset CONTEXT

	run source "$SCRIPT"
	assert_equal "$status" "1"
	assert_line "   ❌ CONTEXT is not set or is not valid JSON"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run this script from a workflow executed with np service workflow exec --build-context"

	export CONTEXT="not json"
	run source "$SCRIPT"
	assert_equal "$status" "1"
	assert_line "   ❌ CONTEXT is not set or is not valid JSON"
}

# =============================================================================
# Hardening: values coming from the context or the scope configuration end up
# in paths and np commands, so they must match a strict shape.
# =============================================================================
@test "Should reject a deployment id that is not an integer" {
	with_context '.deployment.id = "../77"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid deployment id '../77': must be an integer"
	assert_line "  💡 Possible causes:"
	assert_line "    • The context was not produced by the platform (CONTEXT was edited or built by hand)"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run this script from a workflow executed with np service workflow exec --build-context"
}

@test "Should reject a scope id that is not an integer" {
	with_context '.scope.id = "7 8"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid scope id '7 8': must be an integer"
	assert_line "  💡 Possible causes:"
	assert_line "    • The context was not produced by the platform (CONTEXT was edited or built by hand)"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run this script from a workflow executed with np service workflow exec --build-context"
}

@test "Should reject a dimension with path characters" {
	with_context '.scope.dimensions.environment = "../prod"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid dimension '../prod': only lowercase letters, digits and dashes are allowed"
	assert_line "  💡 Possible causes:"
	assert_line "    • The environment dimension of the scope has an unexpected value"
	assert_line "  🔧 How to fix:"
	assert_line "    • Use dimension values made of lowercase letters, digits and dashes only"
	refute_np_called "asset list"
}

@test "Should reject a platform with spaces before touching any path" {
	with_context '.scope.capabilities.platform = "and roid"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unsupported platform 'and roid'"
	assert_line "    • The scope capability platform is not one of: android, ios, both"
	refute_np_called "asset list"
}

@test "Should reject an assets bucket with path characters" {
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"
	with_context '.providers["scope-configurations"].assets.bucket = "../assets bucket"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid assets bucket '../assets bucket': only lowercase letters, digits, dots and dashes are allowed"
	assert_line "  💡 Possible causes:"
	assert_line "    • The assets.bucket field of the 'Mobile store' scope configuration (or ASSETS_BUCKET) is not a bare bucket name"
	assert_line "  🔧 How to fix:"
	assert_line "    • Set assets.bucket to the bucket name only (no scheme, path or spaces)"
	refute_np_called "asset list"
}

@test "Should reject an assets region with spaces or path characters" {
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"
	with_context '.providers["scope-configurations"].assets.region = "us east/../1"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid assets region 'us east/../1': only lowercase letters, digits and dashes are allowed"
	assert_line "  💡 Possible causes:"
	assert_line "    • The assets.region field of the 'Mobile store' scope configuration (or ASSETS_REGION) is not a region name"
	assert_line "  🔧 How to fix:"
	assert_line "    • Set assets.region to a region name such as us-east-1"
	refute_np_called "asset list"
}

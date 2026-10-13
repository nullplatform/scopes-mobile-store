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

	unset NP_MOCK_SCOPE_READ ASSET_NAME SIGNING_LAYER DISTRIBUTION_LAYER GATE_LAYER ASSETS_BUCKET ASSETS_REGION BUILD_CONTEXT_MODE BUILD_CONTEXT_REQUIRE WORKDIR_BASE SCOPE_ID
}

teardown() {
	rm -rf "$TEST_TMP_DIR"
	# A test that must create something outside its tmpdir names it here.
	if [ -n "${EXTRA_CLEANUP_DIR:-}" ]; then
		rm -rf "$EXTRA_CLEANUP_DIR"
	fi
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
	assert_equal "$ASSET_NAME" "android"

	assert_equal "$SIGNING_LAYER" "prebuilt"
	assert_equal "$DISTRIBUTION_LAYER" "firebase"
	assert_equal "$GATE_LAYER" "none"
	assert_equal "$ASSETS_BUCKET" "assets-aws-mobile"
	assert_equal "$ASSETS_REGION" "us-east-1"

	local expected_assets='{
	"android": {
		"url": "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk",
		"asset_id": 6,
		"build_id": 10,
		"name": "android"
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
	assert_np_called "np deployment list --scope-id 7 --all --max-pages 5 --format json"
	assert_np_called "np release read --id 60 --format json"

	assert_equal "$WORKDIR_BASE" "$TEST_TMP_DIR/work"
	assert_equal "$WORKDIR" "$TEST_TMP_DIR/work/77"
	assert_directory_exists "$WORKDIR"

	# The asset in the context already matches android: no listing needed.
	refute_np_called "asset list"
}

@test "Should keep the same workdir when sourced twice in the same session" {
	run_build_context
	run_build_context

	assert_equal "$WORKDIR_BASE" "$TEST_TMP_DIR/work"
	assert_equal "$WORKDIR" "$TEST_TMP_DIR/work/77"
}

@test "Should print a readable summary without dumping the scope configuration" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Building deployment context..."
	assert_line "   📋 Scope: mobile/sample/store (id 7) | Dimension: uat | Deployment: 77 | Release: 1.0.0"
	assert_line "   📋 Platforms: android | Channel: internal | Rollout: 5%"
	assert_line "   📋 Scope configuration: resolved from the platform (nrn organization=1:account=2:namespace=3:application=442353687)"
	assert_line "   ✅ signing_layer=prebuilt"
	assert_line "   ✅ distribution_layer=firebase"
	assert_line "   ✅ gate_layer=none"
	assert_line "   ✅ assets_bucket=assets-aws-mobile (region us-east-1)"
	assert_line "   📋 Asset name: android (from the scope)"
	assert_line "📡 Resolving build assets (type bundle, build 10)..."
	assert_line "   ✅ android: android -> s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk (release 1.0.0, build 10)"
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
		"build_id": 10,
		"name": "android"
	},
	"ios": {
		"url": "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.ipa",
		"asset_id": 12,
		"build_id": 10,
		"name": "ios"
	}
	}'
	assert_json_equal "$ASSETS_JSON" "$expected_assets" "ASSETS_JSON"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
	assert_np_called "np asset list --build-id 10 --format json"
}

@test "Should fail with the full troubleshooting block when the ios binary is missing for platform both" {
	with_context '.scope.capabilities.platform = "both"'
	# asset_list.json only has an ios of another type: it must not be picked.

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ No asset named 'ios' of type 'bundle' in release 1.0.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI did not register an asset named 'ios' for this build"
	assert_line "    • The scope's asset name does not match the name the CI registers"
	assert_line "  🔧 How to fix:"
	assert_line "    • Register an asset named 'ios' (type bundle) in the CI, or change the scope's asset name"
}

@test "Should pick the asset named by the scope even when the context carries another one" {
	with_context '.scope.asset_name = "android-prod"'

	run_build_context

	assert_equal "$ASSET_NAME" "android-prod"
	local expected_assets='{
	"android": {
		"url": "s3://assets-aws-mobile/mobile/442353687/10/prod/app-release.apk",
		"asset_id": 8,
		"build_id": 10,
		"name": "android-prod"
	}
	}'
	assert_json_equal "$ASSETS_JSON" "$expected_assets" "ASSETS_JSON"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/prod/app-release.apk"
	assert_np_called "np asset list --build-id 10 --format json"
}

@test "Should not derive the asset name from the environment dimension" {
	# The dimension says prod, the scope says android: the scope wins.
	with_context '.scope.dimensions.environment = "prod"'

	run_build_context

	assert_equal "$DIMENSION" "prod"
	assert_equal "$ASSET_NAME" "android"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
	refute_np_called "asset list"
}

@test "Should fail with an actionable message when the build has no asset with the scope's asset name" {
	with_context '.scope.asset_name = "android-staging"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ No asset named 'android-staging' of type 'bundle' in release 1.0.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI did not register an asset named 'android-staging' for this build"
	assert_line "    • The scope's asset name does not match the name the CI registers"
	assert_line "  🔧 How to fix:"
	assert_line "    • Register an asset named 'android-staging' (type bundle) in the CI, or change the scope's asset name"
}

@test "Should warn and still fail when the asset listing itself fails" {
	with_context '.scope.asset_name = "android-prod"'
	unset NP_MOCK_ASSET_LIST

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ⚠️ Could not list the assets of build 10 (np asset list failed)"
	assert_line "   ❌ No asset named 'android-prod' of type 'bundle' in release 1.0.0"
}

@test "Should use the default dimension when the scope has no environment dimension" {
	with_context '.scope.dimensions = {}'

	run_build_context

	assert_equal "$DIMENSION" "default"
	assert_equal "$ASSET_NAME" "android"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
}

@test "Should filter the listed assets by the type of the asset in the context" {
	with_context '.asset.type = "mobile-binary" | .scope.asset_name = "android-prod"'
	# The build lists an android-prod of type bundle: it must not match a mobile-binary scope.

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "📡 Resolving build assets (type mobile-binary, build 10)..."
	assert_line "   ❌ No asset named 'android-prod' of type 'mobile-binary' in release 1.0.0"
	assert_line "    • Register an asset named 'android-prod' (type mobile-binary) in the CI, or change the scope's asset name"
	assert_np_called "np asset list --build-id 10 --format json"
}

# =============================================================================
# Asset name: the scope's asset_name, read from the scope, or the platform
# =============================================================================
# Writes a build listing with one bundle per name, all of build 10.
write_asset_listing() {
	local names="$1"
	jq -n --arg names "$names" '{results: ($names | split(" ") | to_entries | map({
		id: (100 + .key), build_id: 10, name: .value, type: "bundle",
		url: ("s3://assets-aws-mobile/mobile/442353687/10/" + .value + "/app"), metadata: {}
	}))}' > "$TEST_TMP_DIR/assets.json"
	export NP_MOCK_ASSET_LIST="$TEST_TMP_DIR/assets.json"
}

@test "Should read the asset name from the scope when the context does not carry it" {
	with_context 'del(.scope.asset_name)'
	echo '{"id": 7, "asset_name": "android"}' > "$TEST_TMP_DIR/scope.json"
	export NP_MOCK_SCOPE_READ="$TEST_TMP_DIR/scope.json"

	run_build_context

	assert_equal "$ASSET_NAME" "android"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
	assert_np_called "np scope read --id 7 --format json"
}

@test "Should fail, not guess the asset name, when the context has none and the scope cannot be read" {
	with_context 'del(.scope.asset_name)'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not read scope '7' to resolve its asset name"
	assert_line "   📋 np scope read answered: {\"error\": \"no mock response configured for: np \"}"
	refute_np_called "asset list"
}

@test "Should fail when the scope read answers garbage" {
	with_context 'del(.scope.asset_name)'
	echo 'garbage' > "$TEST_TMP_DIR/scope.json"
	export NP_MOCK_SCOPE_READ="$TEST_TMP_DIR/scope.json"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not read scope '7' to resolve its asset name"
}

@test "Should default the asset name to the platform when neither the context nor the scope has one" {
	with_context 'del(.scope.asset_name) | .scope.capabilities.platform = "ios"'
	echo '{"id": 7, "asset_name": null}' > "$TEST_TMP_DIR/scope.json"
	export NP_MOCK_SCOPE_READ="$TEST_TMP_DIR/scope.json"
	write_asset_listing "ios android"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 Asset name: ios (default: the scope has no asset name)"
	assert_line "   ✅ ios: ios -> s3://assets-aws-mobile/mobile/442353687/10/ios/app (release 1.0.0, build 10)"
}

@test "Should swap the platform prefix of the asset name for ios when platform is both" {
	with_context '.scope.capabilities.platform = "both" | .scope.asset_name = "android-internal"'
	write_asset_listing "android-internal ios-internal ios"

	run_build_context

	assert_equal "$ASSET_NAME" "android-internal"
	assert_equal "$(echo "$ASSETS_JSON" | jq -r '.android.name')" "android-internal"
	assert_equal "$(echo "$ASSETS_JSON" | jq -r '.ios.name')" "ios-internal"
	assert_equal "$(echo "$ASSETS_JSON" | jq -r '.ios.url')" "s3://assets-aws-mobile/mobile/442353687/10/ios-internal/app"
}

@test "Should use ios as the ios asset when the asset name is android and platform is both" {
	with_context '.scope.capabilities.platform = "both" | .scope.asset_name = "android"'
	write_asset_listing "android ios"

	run_build_context

	assert_equal "$ASSET_NAME" "android"
	assert_equal "$(echo "$ASSETS_JSON" | jq -r '.ios.name')" "ios"
	# android comes from the context asset; ios from the build listing.
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk"
	assert_equal "$(echo "$ASSETS_JSON" | jq -r '.ios.url')" "s3://assets-aws-mobile/mobile/442353687/10/ios/app"
}

@test "Should fail explaining the convention when the ios asset name cannot be derived for platform both" {
	with_context '.scope.capabilities.platform = "both" | .scope.asset_name = "mobile-prod"'
	write_asset_listing "mobile-prod ios-prod"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Cannot derive the ios asset name from the scope's asset name 'mobile-prod'"
	assert_line "    • For a scope with both platforms, name its asset 'android' or 'android-<suffix>': the ios binary is then 'ios' or 'ios-<suffix>'"
	refute_np_called "asset list"
}

@test "Should reject an invalid asset name before listing assets" {
	with_context '.scope.asset_name = "../prod"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid asset name '../prod': it must match ^[a-z0-9][a-z0-9._-]*\$ (lowercase letters, digits, dots, underscores and dashes, starting with a letter or digit)"
	refute_np_called "asset list"
}

@test "Should resolve the asset name in rollback mode without listing the current assets" {
	export BUILD_CONTEXT_MODE="rollback"
	with_context '.scope.asset_name = "android-prod"'

	run_build_context

	assert_equal "$ASSET_NAME" "android-prod"
	assert_equal "$ASSETS_JSON" "{}"
	refute_np_called "asset list"
}

@test "Should not resolve the asset name in scope mode" {
	export BUILD_CONTEXT_MODE="scope"
	with_context 'del(.scope.asset_name)'

	run_build_context

	assert_empty "$ASSET_NAME" "ASSET_NAME"
	refute_np_called "scope read"
}

@test "Should fail before listing assets when the release has no build id" {
	with_context 'del(.asset) | del(.release.build_id)'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The release has no build id"
	assert_line "  💡 Possible causes:"
	assert_line "    • The context carries no asset and the release is not linked to a build"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create the release from a build whose CI registered the mobile binaries as assets"
	refute_np_called "asset list"
}

@test "Should resolve the same context when the asset carries no metadata (the platform does not persist it)" {
	with_context '.asset.metadata = {}'

	run_build_context

	local expected_assets='{
	"android": {
		"url": "s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk",
		"asset_id": 6,
		"build_id": 10,
		"name": "android"
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
	# provider_list.json lists account, namespace and application level providers out of
	# order (plus a static-files one): the deepest NRN must win, not the last element.
	run_build_context

	assert_equal "$(echo "$SCOPE_CONFIGURATION" | jq -r .marker)" "application-level"
	assert_equal "$(echo "$SCOPE_CONFIGURATION" | jq -r .firebase.project)" "np-mobile-pc"
	assert_equal "$(echo "$CONTEXT" | jq -r '.providers["scope-configurations"].marker')" "application-level"
	assert_np_called "np provider list --nrn organization=1:account=2:namespace=3:application=442353687:scope=7 --categories scope-configurations --show-ascendants --dimensions environment:uat --format json"
}

@test "Should fall back to the scope configuration of the context when the platform lookup finds nothing" {
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 Scope configuration: taken from the context"
	refute_line "   ⚠️ Could not resolve the Mobile store scope configuration from the platform; trusting the context, which may belong to another scope type"
	run_build_context
	assert_equal "$(echo "$SCOPE_CONFIGURATION" | jq -r .marker)" "from-context"
	assert_equal "$SIGNING_LAYER" "prebuilt"
	assert_equal "$ASSETS_BUCKET" "assets-aws-mobile"
}

@test "Should warn and trust the context when np is not available" {
	# Only the system directories: no np mock, no real np (jq still resolves).
	export PATH="/usr/bin:/bin"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not resolve the Mobile store scope configuration from the platform; trusting the context, which may belong to another scope type"
	assert_line "   📋 Scope configuration: taken from the context"
	assert_line "   ✅ assets_bucket=assets-aws-mobile (region us-east-1)"
	assert_line "   ⚠️ Could not list the deployments of scope 7; continuing without a previous deployment"
	assert_line "✨ Build context ready"
}

@test "Should warn and trust the context when the provider listing returns an error" {
	unset NP_MOCK_PROVIDER_LIST

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not resolve the Mobile store scope configuration from the platform; trusting the context, which may belong to another scope type"
	assert_line "   📋 Scope configuration: taken from the context"
	run_build_context
	assert_equal "$(echo "$SCOPE_CONFIGURATION" | jq -r .marker)" "from-context"
}

@test "Should warn and trust the context when the mobile-store specification does not exist" {
	export NP_MOCK_SPECIFICATION_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not resolve the Mobile store scope configuration from the platform; trusting the context, which may belong to another scope type"
	assert_line "   📋 Scope configuration: taken from the context"
	refute_np_called "np provider list"
}

@test "Should treat a context configuration without signing_layer as missing when the lookup fails" {
	unset NP_MOCK_PROVIDER_LIST
	with_context '.providers["scope-configurations"] = {"cloud_provider": "aws", "distribution": {"aws_distribution": "cloudfront"}, "gate_layer": "none"}'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ⚠️ Could not resolve the Mobile store scope configuration from the platform; trusting the context, which may belong to another scope type"
	assert_line "   📋 Scope configuration: taken from environment variables"
	assert_line "   ❌ Scope configuration is incomplete: missing signing_layer, distribution_layer, gate_layer, assets.bucket"
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
@test "Should prefer the finalized deployment still active in the scope over a more recent inactive one" {
	# deployment_list.json: 73 finalized/inactive is newer than 70 finalized/active.
	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   📋 Previous deployment: 70 (release 0.9.0)"

	run_build_context
	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "70"
	assert_equal "$PREVIOUS_RELEASE_SEMVER" "0.9.0"
	assert_np_called "np deployment list --scope-id 7"
	assert_np_called "np release read --id 60"
}

@test "Should pick the most recent finalized deployment when none is active in the scope" {
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list_no_active.json"

	run_build_context

	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "69"
	assert_equal "$PREVIOUS_RELEASE_SEMVER" "0.9.0"
	assert_np_called "np deployment list --scope-id 7"
	assert_np_called "np release read --id 58"
}

@test "Should leave the previous deployment empty when only failed or rolled back deployments exist" {
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list_no_previous.json"

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   📋 Previous deployment: none"

	run_build_context
	assert_empty "$PREVIOUS_DEPLOYMENT_ID" "PREVIOUS_DEPLOYMENT_ID"
	assert_empty "$PREVIOUS_RELEASE_SEMVER" "PREVIOUS_RELEASE_SEMVER"
	assert_np_called "np deployment list --scope-id 7"
	refute_np_called "release read"
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
	unset WORKDIR WORKDIR_BASE
	# The default lives outside the test tmpdir: teardown removes it however the test ends.
	EXTRA_CLEANUP_DIR="/tmp/mobile-store/77"

	run_build_context

	assert_equal "$WORKDIR_BASE" "/tmp/mobile-store"
	assert_equal "$WORKDIR" "/tmp/mobile-store/77"
	assert_directory_exists "$WORKDIR"
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
	refute_np_called "provider"
	refute_np_called "deployment list"
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
	refute_np_called "provider"
	refute_np_called "deployment list"
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

# =============================================================================
# Review follow-ups
# =============================================================================
@test "Should ignore an active deployment that is not finalized when picking the previous one" {
	# deployment_list.json lists 78 (failed, active, newest) above 70 (finalized, active)
	run_build_context
	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "70"
	assert_equal "$PREVIOUS_RELEASE_SEMVER" "0.9.0"
}

@test "Should write the configuration synthesized from environment variables back into the context" {
	export CONTEXT=$(echo "$CONTEXT" | jq 'del(.providers["scope-configurations"])')
	unset NP_MOCK_PROVIDER_LIST NP_MOCK_PROVIDER_LIST_WITH_DIMENSIONS
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"
	export SIGNING_LAYER=prebuilt DISTRIBUTION_LAYER=firebase GATE_LAYER=none ASSETS_BUCKET=assets-aws-mobile
	run_build_context
	assert_json_equal "$(echo "$CONTEXT" | jq -c '.providers["scope-configurations"]')" \
		'{"signing_layer":"prebuilt","distribution_layer":"firebase","gate_layer":"none","assets":{"bucket":"assets-aws-mobile","region":"us-east-1"}}'
}

# =============================================================================
# Scope mode (BUILD_CONTEXT_MODE=scope): the scope and instance workflows have
# no deployment, release or asset; only the scope configuration is resolved.
# =============================================================================
scope_context() {
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.deployment, .release, .asset)')
	export CONTEXT
	export BUILD_CONTEXT_MODE="scope"
}

@test "Should resolve the scope configuration without release, asset or deployments in scope mode" {
	scope_context

	run_build_context

	assert_equal "$DIMENSION" "uat"
	assert_equal "$PLATFORMS" "android"
	assert_equal "$CHANNEL" "internal"
	assert_equal "$SCOPE_ID" "7"
	assert_empty "$DEPLOYMENT_ID" "DEPLOYMENT_ID"
	assert_empty "$RELEASE_SEMVER" "RELEASE_SEMVER"
	assert_equal "$SIGNING_LAYER" "prebuilt"
	assert_equal "$DISTRIBUTION_LAYER" "firebase"
	assert_equal "$GATE_LAYER" "none"
	assert_equal "$ASSETS_BUCKET" "assets-aws-mobile"
	assert_equal "$ASSET_TYPE" "bundle"
	assert_equal "$ASSETS_JSON" "{}"
	assert_empty "$ASSET_URL" "ASSET_URL"
	assert_empty "$ASSET_BUILD_NUMBER" "ASSET_BUILD_NUMBER"
	assert_equal "$ANDROID_PACKAGE" "ar.io.nullplatform.sample"
	assert_empty "$PREVIOUS_DEPLOYMENT_ID" "PREVIOUS_DEPLOYMENT_ID"
	assert_empty "$PREVIOUS_RELEASE_SEMVER" "PREVIOUS_RELEASE_SEMVER"
	[[ "$WORKDIR" == "$TEST_TMP_DIR/work/scope-7-"* ]]
	assert_directory_exists "$WORKDIR"

	refute_np_called "asset list"
	refute_np_called "deployment list"
	refute_np_called "release read"
}

@test "Should print the scope mode summary" {
	scope_context

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Building scope context..."
	assert_line "   📋 Scope: mobile/sample/store (id 7) | Dimension: uat"
	assert_line "   📋 Platforms: android | Channel: internal | Rollout: 5%"
	assert_line "   ✅ distribution_layer=firebase"
	assert_line "   📋 Assets of the current release: skipped (scope mode)"
	assert_line "   📋 Previous deployment: skipped (scope mode)"
	[[ "$output" == *"   📋 Workdir: $TEST_TMP_DIR/work/scope-7-"* ]]
	assert_line "✨ Build context ready"
	refute_line "📡 Resolving build assets (type bundle, build 10)..."
}

@test "Should keep the deployment id and workdir in scope mode when the context has a deployment" {
	export BUILD_CONTEXT_MODE="scope"

	run_build_context

	assert_equal "$DEPLOYMENT_ID" "77"
	assert_equal "$RELEASE_SEMVER" "1.0.0"
	assert_equal "$WORKDIR" "$TEST_TMP_DIR/work/77"
	assert_equal "$ASSETS_JSON" "{}"
	refute_np_called "deployment list"
}

@test "Should still validate a deployment id present in scope mode" {
	export BUILD_CONTEXT_MODE="scope"
	with_context '.deployment.id = "../etc"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid deployment id '../etc': must be an integer"
}

@test "Should fail on an unknown BUILD_CONTEXT_MODE" {
	export BUILD_CONTEXT_MODE="instance"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unknown BUILD_CONTEXT_MODE 'instance': expected deployment, rollback or scope"
	assert_line "  💡 Possible causes:"
	assert_line "    • The workflow step that runs build_context sets configuration.BUILD_CONTEXT_MODE to an unexpected value"
	assert_line "  🔧 How to fix:"
	assert_line "    • Set BUILD_CONTEXT_MODE to scope (scope and instance workflows), rollback (rollback workflow) or leave it unset (deployment workflows)"
}

@test "Should still require a deployment in the default mode" {
	with_context 'del(.deployment)'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid deployment id '': must be an integer"
}

@test "Should give every scope-mode run its own workdir" {
	scope_context

	run_build_context
	local first="$WORKDIR"
	echo '{}' > "$first/firebase-sa.json"
	run_build_context

	[[ "$first" == "$TEST_TMP_DIR/work/scope-7-"* ]]
	[[ "$WORKDIR" == "$TEST_TMP_DIR/work/scope-7-"* ]]
	[ "$first" != "$WORKDIR" ]
	assert_file_exists "$first/firebase-sa.json"
	assert_file_not_exists "$WORKDIR/firebase-sa.json"
}

@test "Should refuse a scope-mode context that belongs to another scope than the requested one" {
	scope_context
	export SCOPE_ID="99"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The context belongs to scope 7, not to the requested scope 99"
	assert_line "  💡 Possible causes:"
	assert_line "    • build-context resolved a different scope than the one the notification asks about"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the workflow with np service workflow exec --build-context and .notification.parameters.scope_id set to the requested scope"
}

@test "Should accept a scope-mode context of the requested scope" {
	scope_context
	export SCOPE_ID="7"

	run source "$SCRIPT"

	assert_equal "$status" "0"
}

@test "Should only require the distribution layer and the assets bucket with BUILD_CONTEXT_REQUIRE=distribution" {
	scope_context
	export BUILD_CONTEXT_REQUIRE="distribution"
	export NP_MOCK_PROVIDER_LIST="$TEST_TMP_DIR/provider_list.json"
	jq '.results |= map(.attributes |= del(.signing_layer, .gate_layer))' "$MOCKS_DIR/scope_configuration/provider_list.json" > "$NP_MOCK_PROVIDER_LIST"

	run_build_context

	assert_equal "$DISTRIBUTION_LAYER" "firebase"
	assert_empty "$SIGNING_LAYER" "SIGNING_LAYER"
	assert_empty "$GATE_LAYER" "GATE_LAYER"
}

@test "Should still require signing and gate layers by default" {
	scope_context
	export NP_MOCK_PROVIDER_LIST="$TEST_TMP_DIR/provider_list.json"
	jq '.results |= map(.attributes |= del(.signing_layer, .gate_layer))' "$MOCKS_DIR/scope_configuration/provider_list.json" > "$NP_MOCK_PROVIDER_LIST"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Scope configuration is incomplete: missing signing_layer, gate_layer"
}

# =============================================================================
# Rollback mode: the previous deployment, never the assets of the current release
# =============================================================================
@test "Should resolve the previous deployment without the assets of the current build in rollback mode" {
	export BUILD_CONTEXT_MODE="rollback"
	with_context 'del(.asset) | .release.build_id = 404'
	echo '{"results":[]}' > "$TEST_TMP_DIR/no_assets.json"
	export NP_MOCK_ASSET_LIST="$TEST_TMP_DIR/no_assets.json"

	run_build_context

	assert_equal "$DEPLOYMENT_ID" "77"
	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "70"
	assert_equal "$PREVIOUS_RELEASE_SEMVER" "0.9.0"
	assert_equal "$ASSETS_JSON" "{}"
	assert_equal "$WORKDIR" "$TEST_TMP_DIR/work/77"
	refute_np_called "asset list"
}

@test "Should report no previous deployment in rollback mode when there is none" {
	export BUILD_CONTEXT_MODE="rollback"
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list_no_previous.json"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 Assets of the current release: skipped (rollback mode)"
	assert_line "   📋 Previous deployment: none"
}

@test "Should still require the deployment id in rollback mode" {
	export BUILD_CONTEXT_MODE="rollback"
	with_context 'del(.deployment)'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid deployment id '': must be an integer"
}

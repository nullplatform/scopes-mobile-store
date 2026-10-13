# =============================================================================
# Shared helpers for the mobile-store BATS tests, on top of testing/assertions.sh
#
# bats-assert is not a dependency of the test runner, so the line assertions
# live here. Both work on the `lines` array that `run` fills in.
# =============================================================================

# Assert that `run` produced exactly this line (whole line, whitespace included).
assert_line() {
	local expected="$1" line
	for line in "${lines[@]}"; do
		if [ "$line" = "$expected" ]; then
			return 0
		fi
	done
	echo "Expected line not found: '$expected'"
	echo "Output was:"
	echo "$output"
	return 1
}

# Assert that `run` did not produce this exact line.
refute_line() {
	local unexpected="$1" line
	for line in "${lines[@]}"; do
		if [ "$line" = "$unexpected" ]; then
			echo "Unexpected line found: '$unexpected'"
			echo "Output was:"
			echo "$output"
			return 1
		fi
	done
}

# Assert that the np mock was (or was not) invoked with a command containing the text.
assert_np_called() {
	local needle="$1"
	if ! grep -qF -- "$needle" "$NP_MOCK_CALLS_LOG" 2>/dev/null; then
		echo "Expected an np call containing: '$needle'"
		echo "np calls were:"
		cat "$NP_MOCK_CALLS_LOG" 2>/dev/null || echo "(none)"
		return 1
	fi
}

refute_np_called() {
	local needle="$1"
	if grep -qF -- "$needle" "$NP_MOCK_CALLS_LOG" 2>/dev/null; then
		echo "Did not expect an np call containing: '$needle'"
		echo "np calls were:"
		cat "$NP_MOCK_CALLS_LOG"
		return 1
	fi
}

# Assert that a mock command log (aws, firebase, apksigner, curl) holds exactly this line.
assert_mock_call() {
	local log="$1" expected="$2"
	if ! grep -qxF -- "$expected" "$log" 2>/dev/null; then
		echo "Expected call not found: '$expected'"
		echo "Calls were:"
		cat "$log" 2>/dev/null || echo "(none)"
		return 1
	fi
}

# Assert that no line of `run`'s output (nor the mock logs) carries the text.
refute_output_contains() {
	local secret="$1"
	if [[ "$output" == *"$secret"* ]]; then
		echo "Output leaks '$secret':"
		echo "$output"
		return 1
	fi
}

# =============================================================================
# Layer tests: the contract build_context exports, the CLI mocks on PATH and a
# fresh WORKDIR. Call from setup() with the deployment directory.
# =============================================================================
setup_layer_test() {
	DEPLOYMENT_DIR="$1"
	SCOPE_DIR="$(cd "$DEPLOYMENT_DIR/.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	RESOURCES_DIR="$DEPLOYMENT_DIR/tests/resources"
	MOCKS_DIR="$RESOURCES_DIR/mocks"

	TEST_TMP_DIR=$(mktemp -d)
	export SERVICE_PATH="$SCOPE_DIR"
	export PATH="$MOCKS_DIR:$PATH"

	export CONTEXT
	CONTEXT=$(cat "$RESOURCES_DIR/context_initial.json")
	export SCOPE_CONFIGURATION
	# Real-looking ids: the layers validate their shape before using them.
	SCOPE_CONFIGURATION=$(echo "$CONTEXT" | jq -c '.providers["scope-configurations"]
		| .android.keystore_secret = "mobile/android-keystore"
		| .firebase.app_id_android = "1:726762523137:android:a700b1fa49f91e41eb0e00"')

	export DIMENSION="uat"
	export PLATFORMS="android"
	export CHANNEL="internal"
	export ROLLOUT_PERCENTAGE="5"
	export RELEASE_SEMVER="1.0.0"
	export DEPLOYMENT_ID="77"
	export SCOPE_ID="7"
	export APPLICATION_SLUG="sample"
	export SIGNING_LAYER="prebuilt"
	export DISTRIBUTION_LAYER="firebase"
	export GATE_LAYER="none"
	export ASSETS_BUCKET="assets-aws-mobile"
	export ASSETS_REGION="us-east-1"
	export ASSET_TYPE="bundle"
	export ASSET_NAME="android"
	export ASSETS_JSON='{"android":{"url":"s3://assets-aws-mobile/mobile/442353687/10/uat/app-release.apk","asset_id":6,"build_id":10,"name":"android"}}'
	export ANDROID_PACKAGE="ar.io.nullplatform.sample"
	export IOS_BUNDLE_ID=""
	export PREVIOUS_DEPLOYMENT_ID="70"
	export PREVIOUS_RELEASE_SEMVER="0.9.0"
	export FIREBASE_CLI_VERSION="14.27.0"
	export WORKDIR="$TEST_TMP_DIR/work/77"
	mkdir -p "$WORKDIR"

	export NP_MOCK_CALLS_LOG="$TEST_TMP_DIR/np_calls.log"
	export AWS_MOCK_CALLS_LOG="$TEST_TMP_DIR/aws_calls.log"
	export FIREBASE_MOCK_LOG="$TEST_TMP_DIR/firebase_calls.log"
	export APKSIGNER_MOCK_LOG="$TEST_TMP_DIR/apksigner_calls.log"
	export CURL_MOCK_CALLS_LOG="$TEST_TMP_DIR/curl_calls.log"
	export AWS_MOCK_SECRETS_DIR="$TEST_TMP_DIR/secrets"
	mkdir -p "$AWS_MOCK_SECRETS_DIR"
	export AWS_MOCK_S3_OBJECT="$TEST_TMP_DIR/fixture.apk"
	make_fixture_apk "$AWS_MOCK_S3_OBJECT"

	export NP_MOCK_RELEASE_LIST="$MOCKS_DIR/release_list.json"
	export NP_MOCK_ASSET_LIST="$MOCKS_DIR/asset_list_previous.json"
	export NP_MOCK_DEPLOYMENT_PATCH="$MOCKS_DIR/deployment_patch.json"

	unset NP_MOCK_SCOPE_READ NP_MOCK_SCOPE_PATCH
	unset BINARY_PATH_ANDROID BINARY_PATH_IOS SIGNED_BINARY_PATH_ANDROID SIGNED_BINARY_PATH_IOS
	unset FIREBASE_PROJECT FIREBASE_APP_ID_ANDROID FIREBASE_APP_ID_IOS GOOGLE_APPLICATION_CREDENTIALS
	unset GATE_RESULT FIREBASE_MOCK_FAIL FIREBASE_MOCK_OUTPUT AWS_MOCK_S3_FAIL APKSIGNER_MOCK_FAIL
	unset CURL_MOCK_RESPONSE CURL_MOCK_FAIL FIREBASE_ACCESS_TOKEN
}

teardown_layer_test() {
	rm -rf "$TEST_TMP_DIR"
}

# A minimal APK: a zip that carries an AndroidManifest.xml.
make_fixture_apk() {
	local target="$1" dir
	dir=$(mktemp -d)
	: > "$dir/AndroidManifest.xml"
	(cd "$dir" && zip -q "$target" AndroidManifest.xml)
	rm -rf "$dir"
}

# A minimal IPA: a zip with Payload/<name>.app/Info.plist.
make_fixture_ipa() {
	local target="$1" dir
	dir=$(mktemp -d)
	mkdir -p "$dir/Payload/Sample.app"
	: > "$dir/Payload/Sample.app/Info.plist"
	(cd "$dir" && zip -qr "$target" Payload)
	rm -rf "$dir"
}

# A zip that is neither an APK nor an IPA.
make_fixture_zip() {
	local target="$1" dir
	dir=$(mktemp -d)
	echo "not a mobile binary" > "$dir/readme.txt"
	(cd "$dir" && zip -q "$target" readme.txt)
	rm -rf "$dir"
}

# Register a secret the aws mock answers for `secretsmanager get-secret-value`.
write_mock_secret() {
	local secret_id="$1" value="$2"
	printf '%s\n' "$value" > "$AWS_MOCK_SECRETS_DIR/$(echo "$secret_id" | tr '/' '_')"
}

# Point SCOPE_CONFIGURATION at a jq-modified copy of itself.
with_scope_configuration() {
	SCOPE_CONFIGURATION=$(echo "$SCOPE_CONFIGURATION" | jq -c "$1")
	export SCOPE_CONFIGURATION
}

# A service account JSON with a freshly generated RSA key (never a real one).
write_service_account() {
	local target="$1" key
	key=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)
	jq -n --arg key "$key" '{
		type: "service_account",
		project_id: "np-mobile-pc",
		private_key_id: "abc123",
		private_key: ($key + "\n"),
		client_email: "distributor@np-mobile-pc.iam.gserviceaccount.com",
		token_uri: "https://oauth2.googleapis.com/token"
	}' > "$target"
}

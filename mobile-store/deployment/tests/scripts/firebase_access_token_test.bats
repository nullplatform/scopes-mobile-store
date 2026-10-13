#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/firebase_access_token
#
# Prints an OAuth2 access token for the service account in
# GOOGLE_APPLICATION_CREDENTIALS: a JWT signed with openssl exchanged at
# https://oauth2.googleapis.com/token. FIREBASE_ACCESS_TOKEN short-circuits
# the exchange (tests, local runs). curl is the mock in tests/resources/mocks.
#
# Run: bats mobile-store/deployment/tests/scripts/firebase_access_token_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/scripts/firebase_access_token"

	export GOOGLE_APPLICATION_CREDENTIALS="$WORKDIR/firebase-sa.json"
	write_service_account "$GOOGLE_APPLICATION_CREDENTIALS"
	export CURL_MOCK_RESPONSE="$MOCKS_DIR/firebase_api/token.json"
}

teardown() {
	teardown_layer_test
}

base64url_decode() {
	local data="$1"
	data=$(echo "$data" | tr '_-' '/+')
	while [ $(( ${#data} % 4 )) -ne 0 ]; do data="$data="; done
	echo "$data" | base64 -d
}

@test "Should print FIREBASE_ACCESS_TOKEN when it is set without calling Google" {
	export FIREBASE_ACCESS_TOKEN="ya29.injected-token"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_equal "$output" "ya29.injected-token"
	[ ! -f "$CURL_MOCK_CALLS_LOG" ]
}

@test "Should exchange a signed JWT for an access token" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_equal "$output" "ya29.mock-access-token"

	local call assertion header claims
	call=$(grep -F "https://oauth2.googleapis.com/token" "$CURL_MOCK_CALLS_LOG")
	assert_contains "$call" "--data-urlencode grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer"
	assertion=$(echo "$call" | sed 's/.*--data-urlencode assertion=//; s/ .*//')
	header=$(base64url_decode "$(echo "$assertion" | cut -d. -f1)")
	claims=$(base64url_decode "$(echo "$assertion" | cut -d. -f2)")
	assert_json_equal "$header" '{"alg":"RS256","typ":"JWT"}' "JWT header"
	assert_equal "$(echo "$claims" | jq -r '.iss')" "distributor@np-mobile-poc.iam.gserviceaccount.com"
	assert_equal "$(echo "$claims" | jq -r '.scope')" "https://www.googleapis.com/auth/cloud-platform"
	assert_equal "$(echo "$claims" | jq -r '.aud')" "https://oauth2.googleapis.com/token"
	assert_equal "$(echo "$claims" | jq -r '.exp - .iat')" "3600"

	# The signature must verify with the public key of the service account.
	local signing_input signature
	signing_input=$(echo "$assertion" | cut -d. -f1-2)
	jq -r '.private_key' "$GOOGLE_APPLICATION_CREDENTIALS" > "$TEST_TMP_DIR/key.pem"
	openssl pkey -in "$TEST_TMP_DIR/key.pem" -pubout -out "$TEST_TMP_DIR/pub.pem" 2>/dev/null
	base64url_decode "$(echo "$assertion" | cut -d. -f3)" > "$TEST_TMP_DIR/sig.bin"
	run openssl dgst -sha256 -verify "$TEST_TMP_DIR/pub.pem" -signature "$TEST_TMP_DIR/sig.bin" <(printf '%s' "$signing_input")
	assert_equal "$status" "0"
}

@test "Should fail with the full troubleshooting block when Google rejects the JWT" {
	export CURL_MOCK_FAIL="400"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not obtain a Google access token for distributor@np-mobile-poc.iam.gserviceaccount.com"
	assert_line "  💡 Possible causes:"
	assert_line "    • The service account key was deleted or the service account was disabled"
	assert_line "    • The worker clock is off by more than a few minutes"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create a new key for the service account and update the credentials secret"
}

@test "Should fail when GOOGLE_APPLICATION_CREDENTIALS is not a service account" {
	echo '{"api_key":"x"}' > "$GOOGLE_APPLICATION_CREDENTIALS"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ $GOOGLE_APPLICATION_CREDENTIALS is not a Google service account JSON (client_email and private_key are required)"
}

@test "Should fail when GOOGLE_APPLICATION_CREDENTIALS is not set" {
	unset GOOGLE_APPLICATION_CREDENTIALS

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ GOOGLE_APPLICATION_CREDENTIALS is not set"
	assert_line "    • The distribution/firebase layer setup did not run before this step"
}

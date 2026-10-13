#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/distribution/firebase/list_releases
#
# Lists the releases of each Firebase app through the App Distribution REST
# API and prints JSON only (the base of instance/list). The access token comes
# from scripts/firebase_access_token, injectable through FIREBASE_ACCESS_TOKEN;
# curl is the mock in tests/resources/mocks.
#
# Run: bats mobile-store/deployment/tests/distribution/firebase/list_releases_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/distribution/firebase/list_releases"

	export FIREBASE_PROJECT="np-mobile-poc"
	export FIREBASE_APP_ID_ANDROID="1:123:android:abc"
	export FIREBASE_ACCESS_TOKEN="ya29.injected-token"
	export CURL_MOCK_RESPONSE="$MOCKS_DIR/firebase_api/releases_android.json"
}

teardown() {
	teardown_layer_test
}

@test "Should print only JSON with the releases of the android app" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_json_equal "$output" '{
		"results": [
			{
				"platform": "android",
				"app_id": "1:123:android:abc",
				"release": "projects/123/apps/1:123:android:abc/releases/0abcdef",
				"version": "1.0.0",
				"build": "10",
				"created_at": "2025-12-22T18:30:00.000Z",
				"release_notes": "sample 1.0.0 (uat) deployment 77",
				"console_url": "https://console.firebase.google.com/project/np-mobile-poc/appdistribution/app/android:ar.io.nullplatform.sample/releases/0abcdef",
				"testing_url": "https://appdistribution.firebase.google.com/testerapps/1:123:android:abc/releases/0abcdef"
			},
			{
				"platform": "android",
				"app_id": "1:123:android:abc",
				"release": "projects/123/apps/1:123:android:abc/releases/0fedcba",
				"version": "0.9.0",
				"build": "9",
				"created_at": "2025-12-15T09:05:00.000Z",
				"release_notes": null,
				"console_url": "https://console.firebase.google.com/project/np-mobile-poc/appdistribution/app/android:ar.io.nullplatform.sample/releases/0fedcba",
				"testing_url": "https://appdistribution.firebase.google.com/testerapps/1:123:android:abc/releases/0fedcba"
			}
		]
	}' "list_releases output"
	assert_mock_call "$CURL_MOCK_CALLS_LOG" "curl -fsS -H Authorization: Bearer ya29.injected-token https://firebaseappdistribution.googleapis.com/v1/projects/123/apps/1:123:android:abc/releases?pageSize=20"
}

@test "Should query every platform of the scope" {
	export PLATFORMS="android ios"
	export FIREBASE_APP_ID_IOS="1:123:ios:def"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_mock_call "$CURL_MOCK_CALLS_LOG" "curl -fsS -H Authorization: Bearer ya29.injected-token https://firebaseappdistribution.googleapis.com/v1/projects/123/apps/1:123:ios:def/releases?pageSize=20"
	assert_equal "$(echo "$output" | jq -r '.results | length')" "4"
	assert_equal "$(echo "$output" | jq -r '[.results[].platform] | unique | join(",")')" "android,ios"
}

@test "Should print an empty result and the error on stderr when the API call fails" {
	export CURL_MOCK_FAIL="403"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not list the releases of the android app 1:123:android:abc"
	assert_line "  💡 Possible causes:"
	assert_line "    • The service account lacks the Firebase App Distribution Viewer role on project 'np-mobile-poc'"
	assert_line "    • The app id is wrong"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check firebase.app_id_android and the roles of the service account in the Firebase console"
	run bash -c "bash '$SCRIPT' 2>/dev/null"
	assert_json_equal "$output" '{"results": []}' "stdout on failure"
}

@test "Should fail when the Firebase layer was not set up" {
	unset FIREBASE_APP_ID_ANDROID

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ FIREBASE_APP_ID_ANDROID is not set"
}

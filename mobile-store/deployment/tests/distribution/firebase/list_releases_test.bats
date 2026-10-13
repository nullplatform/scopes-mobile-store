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

	export FIREBASE_PROJECT="np-mobile-pc"
	export FIREBASE_APP_ID_ANDROID="1:726762523137:android:a700b1fa49f91e41eb0e00"
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
				"app_id": "1:726762523137:android:a700b1fa49f91e41eb0e00",
				"release": "projects/726762523137/apps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/0abcdef",
				"version": "1.0.0",
				"build": "10",
				"created_at": "2025-12-22T18:30:00.000Z",
				"release_notes": "sample 1.0.0 (uat) deployment 77",
				"console_url": "https://console.firebase.google.com/project/np-mobile-pc/appdistribution/app/android:ar.io.nullplatform.sample/releases/0abcdef",
				"testing_url": "https://appdistribution.firebase.google.com/testerapps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/0abcdef"
			},
			{
				"platform": "android",
				"app_id": "1:726762523137:android:a700b1fa49f91e41eb0e00",
				"release": "projects/726762523137/apps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/0fedcba",
				"version": "0.9.0",
				"build": "9",
				"created_at": "2025-12-15T09:05:00.000Z",
				"release_notes": null,
				"console_url": "https://console.firebase.google.com/project/np-mobile-pc/appdistribution/app/android:ar.io.nullplatform.sample/releases/0fedcba",
				"testing_url": "https://appdistribution.firebase.google.com/testerapps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/0fedcba"
			}
		]
	}' "list_releases output"
	assert_mock_call "$CURL_MOCK_CALLS_LOG" "curl -fsS --connect-timeout 10 --max-time 60 --retry 2 -H @- https://firebaseappdistribution.googleapis.com/v1/projects/726762523137/apps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases?pageSize=20"
}

@test "Should send the bearer token through stdin, never in the curl arguments" {
	export CURL_MOCK_STDIN_LOG="$TEST_TMP_DIR/curl_stdin.log"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_mock_call "$CURL_MOCK_STDIN_LOG" "Authorization: Bearer ya29.injected-token"
	run cat "$CURL_MOCK_CALLS_LOG"
	refute_output_contains "ya29.injected-token"
}

@test "Should remove the service account file when it finishes" {
	export GOOGLE_APPLICATION_CREDENTIALS="$WORKDIR/firebase-sa.json"
	echo '{}' > "$GOOGLE_APPLICATION_CREDENTIALS"

	run bash "$SCRIPT"
	assert_equal "$status" "0"
	assert_file_not_exists "$GOOGLE_APPLICATION_CREDENTIALS"

	echo '{}' > "$GOOGLE_APPLICATION_CREDENTIALS"
	export CURL_MOCK_FAIL="403"
	run bash "$SCRIPT"
	assert_equal "$status" "1"
	assert_file_not_exists "$GOOGLE_APPLICATION_CREDENTIALS"
}

@test "Should not remove a credentials file outside the workdir" {
	export GOOGLE_APPLICATION_CREDENTIALS="$TEST_TMP_DIR/my-own-sa.json"
	echo '{}' > "$GOOGLE_APPLICATION_CREDENTIALS"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_file_exists "$GOOGLE_APPLICATION_CREDENTIALS"
}

@test "Should keep stdout as JSON when the API answers something that is not JSON" {
	printf 'not json' > "$TEST_TMP_DIR/bad.json"
	export CURL_MOCK_RESPONSE="$TEST_TMP_DIR/bad.json"

	run bash -c "bash '$SCRIPT' 2>/dev/null"

	assert_equal "$status" "1"
	assert_json_equal "$output" '{"results": []}' "stdout on a bad answer"
}

@test "Should query every platform of the scope" {
	export PLATFORMS="android ios"
	export FIREBASE_APP_ID_IOS="1:726762523137:ios:b811c2fb50a02f52fc1f11"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_mock_call "$CURL_MOCK_CALLS_LOG" "curl -fsS --connect-timeout 10 --max-time 60 --retry 2 -H @- https://firebaseappdistribution.googleapis.com/v1/projects/726762523137/apps/1:726762523137:ios:b811c2fb50a02f52fc1f11/releases?pageSize=20"
	assert_equal "$(echo "$output" | jq -r '.results | length')" "4"
	assert_equal "$(echo "$output" | jq -r '[.results[].platform] | unique | join(",")')" "android,ios"
}

@test "Should print an empty result and the error on stderr when the API call fails" {
	export CURL_MOCK_FAIL="403"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not list the releases of the android app 1:726762523137:android:a700b1fa49f91e41eb0e00"
	assert_line "  💡 Possible causes:"
	assert_line "    • The service account lacks the Firebase App Distribution Viewer role on project 'np-mobile-pc'"
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

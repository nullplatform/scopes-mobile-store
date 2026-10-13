#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/distribution/firebase/publish
#
# Distributes SIGNED_BINARY_PATH_<PLATFORM> to the Firebase group named by
# CHANNEL and writes $WORKDIR/distribution.json. firebase is the mock in
# tests/resources/mocks, which records the exact command it received.
#
# Run: bats mobile-store/deployment/tests/distribution/firebase/publish_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/distribution/firebase/publish"

	mkdir -p "$WORKDIR/android"
	cp "$AWS_MOCK_S3_OBJECT" "$WORKDIR/android/app.apk"
	export SIGNED_BINARY_PATH_ANDROID="$WORKDIR/android/app.apk"
	export FIREBASE_PROJECT="np-mobile-pc"
	export FIREBASE_APP_ID_ANDROID="1:726762523137:android:a700b1fa49f91e41eb0e00"
	export GOOGLE_APPLICATION_CREDENTIALS="$WORKDIR/firebase-sa.json"
	echo '{}' > "$GOOGLE_APPLICATION_CREDENTIALS"
}

teardown() {
	teardown_layer_test
}

@test "Should distribute the android binary to the channel group with the exact firebase command" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📝 Publishing release 1.0.0 to Firebase App Distribution (group 'internal')"
	assert_line "   📡 android: distributing $WORKDIR/android/app.apk to Firebase group 'internal'"
	assert_line "   ✅ android: distributed to Firebase group 'internal' (release projects/726762523137/apps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/0abcdef)"
	assert_line "✨ Published to Firebase App Distribution: $WORKDIR/distribution.json"
	assert_mock_call "$FIREBASE_MOCK_LOG" "firebase appdistribution:distribute $WORKDIR/android/app.apk --app 1:726762523137:android:a700b1fa49f91e41eb0e00 --project np-mobile-pc --groups internal --release-notes sample 1.0.0 (uat) deployment 77 --non-interactive"
	assert_json_equal "$(cat "$WORKDIR/distribution.json")" '{
		"provider": "firebase",
		"project": "np-mobile-pc",
		"group": "internal",
		"releases": {
			"android": {
				"app_id": "1:726762523137:android:a700b1fa49f91e41eb0e00",
				"name": "projects/726762523137/apps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/0abcdef",
				"group": "internal"
			}
		}
	}' "distribution.json"
}

@test "Should take the release name straight from the output when the CLI prints the resource name" {
	export FIREBASE_MOCK_OUTPUT="release-name"
	export FIREBASE_MOCK_RELEASE_ID="9zyx"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ android: distributed to Firebase group 'internal' (release projects/726762523137/apps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/9zyx)"
}

@test "Should warn and record an unknown release when the CLI output has no release id" {
	export FIREBASE_MOCK_OUTPUT="bare"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ android: the firebase CLI did not report the release name; check the Firebase console for the latest release of 1:726762523137:android:a700b1fa49f91e41eb0e00"
	assert_line "   ✅ android: distributed to Firebase group 'internal' (release unknown)"
	assert_equal "$(jq -r '.releases.android.name' "$WORKDIR/distribution.json")" "null"
}

@test "Should distribute both platforms with the testers group when the channel is testers" {
	export PLATFORMS="android ios"
	export CHANNEL="testers"
	mkdir -p "$WORKDIR/ios"
	make_fixture_ipa "$WORKDIR/ios/app.ipa"
	export SIGNED_BINARY_PATH_IOS="$WORKDIR/ios/app.ipa"
	export FIREBASE_APP_ID_IOS="1:726762523137:ios:b811c2fb50a02f52fc1f11"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ android: distributed to Firebase group 'testers' (release projects/726762523137/apps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/0abcdef)"
	assert_line "   ✅ ios: distributed to Firebase group 'testers' (release projects/726762523137/apps/1:726762523137:ios:b811c2fb50a02f52fc1f11/releases/0abcdef)"
	assert_mock_call "$FIREBASE_MOCK_LOG" "firebase appdistribution:distribute $WORKDIR/ios/app.ipa --app 1:726762523137:ios:b811c2fb50a02f52fc1f11 --project np-mobile-pc --groups testers --release-notes sample 1.0.0 (uat) deployment 77 --non-interactive"
	assert_equal "$(jq -r '.releases | keys | join(",")' "$WORKDIR/distribution.json")" "android,ios"
}

@test "Should fail with the full troubleshooting block when Firebase denies the upload" {
	export FIREBASE_MOCK_FAIL="permission"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ android: Firebase App Distribution rejected the upload of $WORKDIR/android/app.apk"
	assert_line "      Error: HTTP Error: 403, PERMISSION_DENIED"
	assert_line "  💡 Possible causes:"
	assert_line "    • The Firebase service account was revoked or lacks the Firebase App Distribution Admin role"
	assert_line "  🔧 How to fix:"
	assert_line "    • Grant the service account in secret 'mobile/firebase-sa' the Firebase App Distribution Admin role on project 'np-mobile-pc'"
	assert_file_not_exists "$WORKDIR/distribution.json"
}

@test "Should fail with the full troubleshooting block when the Firebase app does not exist" {
	export FIREBASE_MOCK_FAIL="notfound"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ android: Firebase App Distribution rejected the upload of $WORKDIR/android/app.apk"
	assert_line "      Error: HTTP Error: 404, App not found"
	assert_line "  💡 Possible causes:"
	assert_line "    • The app id '1:726762523137:android:a700b1fa49f91e41eb0e00' does not exist in the Firebase project 'np-mobile-pc'"
	assert_line "  🔧 How to fix:"
	assert_line "    • Copy the android app id from the Firebase console (Project settings > Your apps) into firebase.app_id_android"
}

@test "Should fail with a generic troubleshooting block on any other Firebase error" {
	export FIREBASE_MOCK_FAIL="other"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "      Error: HTTP Error: 500, Internal error"
	assert_line "    • Firebase App Distribution is unavailable or rejected the binary (see the output above)"
	assert_line "    • Retry the deployment; if it keeps failing, run the firebase command above with the service account to see the full error"
}

@test "Should fail when the signed binary of a platform is missing" {
	unset SIGNED_BINARY_PATH_ANDROID

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ SIGNED_BINARY_PATH_ANDROID is not set"
	assert_line "  💡 Possible causes:"
	assert_line "    • The signing layer did not run before the distribution"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the deployment workflow from the start so the android binary is downloaded and signed first"
	[ ! -f "$FIREBASE_MOCK_LOG" ]
}

@test "Should fail when the Firebase layer was not set up" {
	unset FIREBASE_PROJECT

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ FIREBASE_PROJECT is not set"
	assert_line "    • The distribution/firebase layer setup did not run before the publish"
}

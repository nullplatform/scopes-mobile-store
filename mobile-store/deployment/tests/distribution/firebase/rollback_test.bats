#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/distribution/firebase/rollback
#
# Firebase App Distribution cannot unpublish a release, so a rollback
# re-distributes the binary of the previous finalized deployment: the asset
# of PREVIOUS_RELEASE_SEMVER is resolved again (np release list / np asset
# list), downloaded, signed by the configured signing layer and distributed
# to the same group.
#
# Run: bats mobile-store/deployment/tests/distribution/firebase/rollback_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/distribution/firebase/rollback"

	export FIREBASE_PROJECT="np-mobile-pc"
	export FIREBASE_APP_ID_ANDROID="1:726762523137:android:a700b1fa49f91e41eb0e00"
	export GOOGLE_APPLICATION_CREDENTIALS="$WORKDIR/firebase-sa.json"
	echo '{}' > "$GOOGLE_APPLICATION_CREDENTIALS"
}

teardown() {
	teardown_layer_test
}

@test "Should fail with the full troubleshooting block when there is no previous finalized deployment" {
	export PREVIOUS_DEPLOYMENT_ID=""
	export PREVIOUS_RELEASE_SEMVER=""

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ No previous finalized deployment to roll back to"
	assert_line "  💡 Possible causes:"
	assert_line "    • This is the first deployment of the scope"
	assert_line "    • Every earlier deployment of the scope failed or was deleted"
	assert_line "  🔧 How to fix:"
	assert_line "    • Firebase App Distribution cannot unpublish a release: remove the testers from group 'internal' in the Firebase console if this build must not be installed"
	assert_line "    • Deploy a known-good release again so it becomes the latest one in the group"
	[ ! -f "$FIREBASE_MOCK_LOG" ]
	[ ! -f "$NP_MOCK_CALLS_LOG" ]
}

@test "Should re-distribute the binary of the previous release with the exact firebase command" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📝 Rolling back to release 0.9.0 (deployment 70) on Firebase App Distribution"
	assert_line "   📋 Firebase cannot unpublish release 1.0.0: the previous build is distributed again to group 'internal'"
	assert_line "   ✅ android: android-uat of release 0.9.0 -> s3://assets-aws-mobile/mobile/442353687/442353600/uat/app-release.apk"
	assert_line "   📡 Downloading s3://assets-aws-mobile/mobile/442353687/442353600/uat/app-release.apk to $WORKDIR/rollback/android/app.apk"
	assert_line "   ✅ android: using the CI-signed binary $WORKDIR/rollback/android/app.apk"
	assert_line "   ✅ android: distributed to Firebase group 'internal' (release projects/726762523137/apps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/0abcdef)"
	assert_line "✨ Rolled back to release 0.9.0 on Firebase App Distribution: $WORKDIR/distribution.json"
	assert_np_called "np release list --application-id 442353687 --limit 200 --format json"
	assert_np_called "np asset list --build-id 442353600 --format json"
	assert_mock_call "$AWS_MOCK_CALLS_LOG" "aws s3 cp s3://assets-aws-mobile/mobile/442353687/442353600/uat/app-release.apk $WORKDIR/rollback/android/app.apk --region us-east-1"
	assert_mock_call "$FIREBASE_MOCK_LOG" "firebase appdistribution:distribute $WORKDIR/rollback/android/app.apk --app 1:726762523137:android:a700b1fa49f91e41eb0e00 --project np-mobile-pc --groups internal --release-notes sample rollback to 0.9.0 (uat) deployment 77 --non-interactive"
	assert_json_equal "$(cat "$WORKDIR/distribution.json")" '{
		"provider": "firebase",
		"project": "np-mobile-pc",
		"group": "internal",
		"rollout_percentage": 100,
		"rollback_to": "0.9.0",
		"releases": {
			"android": {
				"app_id": "1:726762523137:android:a700b1fa49f91e41eb0e00",
				"name": "projects/726762523137/apps/1:726762523137:android:a700b1fa49f91e41eb0e00/releases/0abcdef",
				"group": "internal"
			}
		}
	}' "distribution.json"
}

@test "Should resolve the previous binary with the scope's asset name, not the dimension" {
	export ASSET_NAME="android-prod"
	jq '.results += [{id: 50, build_id: 442353600, name: "android-prod", type: "bundle",
		url: "s3://assets-aws-mobile/mobile/442353687/442353600/prod/app-release.apk", metadata: {}}]' \
		"$MOCKS_DIR/asset_list_previous.json" > "$TEST_TMP_DIR/assets_with_prod.json"
	export NP_MOCK_ASSET_LIST="$TEST_TMP_DIR/assets_with_prod.json"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ android: android-prod of release 0.9.0 -> s3://assets-aws-mobile/mobile/442353687/442353600/prod/app-release.apk"
}

@test "Should fail before resolving the previous release when the ios asset name cannot be derived" {
	export PLATFORMS="android ios"
	export ASSET_NAME="mobile-prod"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Cannot derive the ios asset name from the scope's asset name 'mobile-prod'"
	[ ! -f "$FIREBASE_MOCK_LOG" ]
}

@test "Should fail with the full troubleshooting block when the previous release has no binary for the platform" {
	jq '.results |= map(select(.name != "android-uat"))' "$MOCKS_DIR/asset_list_previous.json" > "$TEST_TMP_DIR/assets_without_android.json"
	export NP_MOCK_ASSET_LIST="$TEST_TMP_DIR/assets_without_android.json"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ No asset named 'android-uat' of type 'bundle' in release 0.9.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI of release 0.9.0 did not register an asset named 'android-uat'"
	assert_line "    • The scope's asset name changed after release 0.9.0 was built"
	assert_line "  🔧 How to fix:"
	assert_line "    • Roll back by deploying another release that carries an 'android-uat' asset"
	[ ! -f "$FIREBASE_MOCK_LOG" ]
}

@test "Should fail when the previous deployment is known but its release is not" {
	export PREVIOUS_RELEASE_SEMVER=""

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The release of the previous deployment 70 is unknown"
	assert_line "  💡 Possible causes:"
	assert_line "    • build_context could not read the release of deployment 70 (np release read failed)"
	assert_line "  🔧 How to fix:"
	assert_line "    • Retry the rollback; if it keeps failing, deploy the previous release again by hand"
}

@test "Should propagate a Firebase failure with its troubleshooting block" {
	export FIREBASE_MOCK_FAIL="permission"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ android: Firebase App Distribution rejected the upload of $WORKDIR/rollback/android/app.apk"
	assert_line "    • The Firebase service account was revoked or lacks the Firebase App Distribution Admin role"
}

# =============================================================================
# Rollback through the real platform and signing layers
# =============================================================================
@test "Should fail with the download troubleshooting block when the previous binary cannot be read" {
	export AWS_MOCK_S3_FAIL=1

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not download the android binary from s3://assets-aws-mobile/mobile/442353687/442353600/uat/app-release.apk"
	assert_line "    • The agent role has no s3:GetObject permission on bucket 'assets-aws-mobile'"
	[ ! -f "$FIREBASE_MOCK_LOG" ]
	assert_file_not_exists "$GOOGLE_APPLICATION_CREDENTIALS"
}

@test "Should sign the previous binary with the keyvault layer before distributing it" {
	export SIGNING_LAYER="keyvault"
	write_mock_secret "mobile/android-keystore" "$(jq -nc --arg ks "$(printf 'fake-jks' | base64)" \
		'{keystore_base64: $ks, keystore_password: "pw", key_alias: "release", key_password: "pw2"}')"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ android: signed $WORKDIR/rollback/android/app.apk -> $WORKDIR/rollback/android/app-signed.apk (alias 'release')"
	assert_mock_call "$APKSIGNER_MOCK_LOG" "apksigner sign --ks $WORKDIR/rollback/android/keystore.jks --ks-pass env:MOBILE_STORE_KEYSTORE_PASSWORD --ks-key-alias release --key-pass env:MOBILE_STORE_KEY_PASSWORD --out $WORKDIR/rollback/android/app-signed.apk $WORKDIR/rollback/android/app.apk"
	assert_mock_call "$FIREBASE_MOCK_LOG" "firebase appdistribution:distribute $WORKDIR/rollback/android/app-signed.apk --app 1:726762523137:android:a700b1fa49f91e41eb0e00 --project np-mobile-pc --groups internal --release-notes sample rollback to 0.9.0 (uat) deployment 77 --non-interactive"
}

@test "Should refuse a previous binary stored outside the configured assets bucket" {
	jq '.results |= map(.url |= sub("assets-aws-mobile"; "someone-elses-bucket"))' "$MOCKS_DIR/asset_list_previous.json" > "$TEST_TMP_DIR/assets_other_bucket.json"
	export NP_MOCK_ASSET_LIST="$TEST_TMP_DIR/assets_other_bucket.json"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Asset URL is outside the configured assets bucket 'assets-aws-mobile': s3://someone-elses-bucket/mobile/442353687/442353600/uat/app-release.apk"
	[ ! -f "$AWS_MOCK_CALLS_LOG" ]
	[ ! -f "$FIREBASE_MOCK_LOG" ]
}

@test "Should remove the service account file when it finishes" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_file_not_exists "$GOOGLE_APPLICATION_CREDENTIALS"
}

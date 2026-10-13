#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/distribution/firebase/setup
#
# The layer validates the firebase section of the scope configuration, writes
# the service account from the secrets manager to $WORKDIR/firebase-sa.json
# and exports the FIREBASE_* variables that publish/rollback use.
#
# Run: bats mobile-store/deployment/tests/distribution/firebase/setup_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/distribution/firebase/setup"

	SERVICE_ACCOUNT='{"type":"service_account","project_id":"np-mobile-pc","private_key":"-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----\n","client_email":"distributor@np-mobile-pc.iam.gserviceaccount.com","token_uri":"https://oauth2.googleapis.com/token"}'
	write_mock_secret "mobile/firebase-sa" "$SERVICE_ACCOUNT"
}

teardown() {
	teardown_layer_test
}

@test "Should validate the configuration, download the credentials and export the FIREBASE_* variables" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Validating Firebase App Distribution configuration..."
	assert_line "   ✅ firebase_project=np-mobile-pc"
	assert_line "   ✅ firebase_app_id_android=1:726762523137:android:a700b1fa49f91e41eb0e00"
	assert_line "   📡 Reading secret 'mobile/firebase-sa'"
	assert_line "   ✅ credentials=$WORKDIR/firebase-sa.json (distributor@np-mobile-pc.iam.gserviceaccount.com)"
	assert_line "✨ Firebase App Distribution configured"
	assert_mock_call "$AWS_MOCK_CALLS_LOG" "aws secretsmanager get-secret-value --secret-id mobile/firebase-sa --query SecretString --output text"

	source "$SCRIPT"
	assert_equal "$FIREBASE_PROJECT" "np-mobile-pc"
	assert_equal "$FIREBASE_APP_ID_ANDROID" "1:726762523137:android:a700b1fa49f91e41eb0e00"
	assert_empty "${FIREBASE_APP_ID_IOS:-}" "FIREBASE_APP_ID_IOS"
	assert_equal "$GOOGLE_APPLICATION_CREDENTIALS" "$WORKDIR/firebase-sa.json"
	assert_json_equal "$(cat "$WORKDIR/firebase-sa.json")" "$SERVICE_ACCOUNT" "service account"
	assert_equal "$(stat -f '%Lp' "$WORKDIR/firebase-sa.json" 2>/dev/null || stat -c '%a' "$WORKDIR/firebase-sa.json")" "600"
}

@test "Should export the ios app id when the scope publishes both platforms" {
	export PLATFORMS="android ios"
	with_scope_configuration '.firebase.app_id_ios = "1:726762523137:ios:b811c2fb50a02f52fc1f11"'

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ firebase_app_id_android=1:726762523137:android:a700b1fa49f91e41eb0e00"
	assert_line "   ✅ firebase_app_id_ios=1:726762523137:ios:b811c2fb50a02f52fc1f11"

	source "$SCRIPT"
	assert_equal "$FIREBASE_APP_ID_IOS" "1:726762523137:ios:b811c2fb50a02f52fc1f11"
}

@test "Should never print the service account" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	refute_output_contains "BEGIN PRIVATE KEY"
	refute_output_contains "private_key"
}

@test "Should fail with the full troubleshooting block when the ios app id is missing" {
	export PLATFORMS="android ios"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ firebase.app_id_ios is missing"
	assert_line "   ❌ The 'Mobile store' scope configuration is incomplete for Firebase App Distribution: missing firebase.app_id_ios"
	assert_line "  💡 Possible causes:"
	assert_line "    • The scope publishes ios binaries but the Firebase section has no app for that platform"
	assert_line "  🔧 How to fix:"
	assert_line "    • Register the app in the Firebase project 'np-mobile-pc' and set the missing field(s) in the scope configuration:"
	assert_line "      • firebase.app_id_ios (e.g. 1:1234567890:ios:abcdef)"
	[ ! -f "$AWS_MOCK_CALLS_LOG" ]
}

@test "Should list every missing field when project, credentials and app id are missing" {
	with_scope_configuration 'del(.firebase)'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ firebase.project is missing"
	assert_line "   ❌ firebase.credentials_secret is missing"
	assert_line "   ❌ firebase.app_id_android is missing"
	assert_line "   ❌ The 'Mobile store' scope configuration is incomplete for Firebase App Distribution: missing firebase.project, firebase.credentials_secret, firebase.app_id_android"
	assert_line "      • firebase.project (the Firebase project id)"
	assert_line "      • firebase.credentials_secret (name of the secret with the service account JSON)"
	assert_line "      • firebase.app_id_android (e.g. 1:1234567890:android:abcdef)"
}

@test "Should fail with the full troubleshooting block when the firebase CLI is not installed" {
	mkdir -p "$TEST_TMP_DIR/bin"
	ln -s "$MOCKS_DIR/aws" "$TEST_TMP_DIR/bin/aws"
	export PATH="$TEST_TMP_DIR/bin:/usr/bin:/bin"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The firebase CLI is not available in the worker image"
	assert_line "  💡 Possible causes:"
	assert_line "    • The worker image was built without firebase-tools"
	assert_line "  🔧 How to fix:"
	assert_line "    • Build the worker image from this repository's Dockerfile (it installs firebase-tools@14) and pin it in the agent"
}

@test "Should fail with the full troubleshooting block when the credentials secret cannot be read" {
	with_scope_configuration '.firebase.credentials_secret = "mobile/missing"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not read secret 'mobile/missing' from the secrets manager"
	assert_line "  💡 Possible causes:"
	assert_line "    • The secret does not exist in region us-east-1"
	assert_line "    • The agent role has no secretsmanager:GetSecretValue permission on it"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create the secret or grant the agent role read access to it"
}

@test "Should fail with the full troubleshooting block when the secret is not a service account" {
	write_mock_secret "mobile/firebase-sa" '{"api_key":"not-a-service-account"}'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Secret 'mobile/firebase-sa' is not a Google service account JSON"
	assert_line "  💡 Possible causes:"
	assert_line "    • The secret holds something other than the JSON key downloaded from the Google Cloud console"
	assert_line "  🔧 How to fix:"
	assert_line "    • Store the full JSON key of a service account with the Firebase App Distribution Admin role"
	refute_output_contains "not-a-service-account"
}

# =============================================================================
# Hardening: secret namespace and the shape of the Firebase ids
# =============================================================================
@test "Should reject a credentials secret outside the mobile/ namespace without reading it" {
	with_scope_configuration '.firebase.credentials_secret = "prod/firebase-sa"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Secret name 'prod/firebase-sa' is outside the mobile/ namespace (firebase.credentials_secret)"
	assert_line "  💡 Possible causes:"
	assert_line "    • The 'Mobile store' scope configuration names a secret this scope is not allowed to read"
	assert_line "  🔧 How to fix:"
	assert_line "    • Store the secret under the mobile/ prefix (e.g. mobile/firebase-sa) and set firebase.credentials_secret to that name"
	[ ! -f "$AWS_MOCK_CALLS_LOG" ]
}

@test "Should reject a Firebase app id that is not shaped like one" {
	local app_id
	for app_id in "1:726762523137:android:a700b1fa49f91e41eb0e00 --token x" "2:726762523137:android:a700b1fa" "1:726762523137:web:a700b1fa" "1:abc:android:a700b1fa" "1:726762523137:android:ZZZ"; do
		with_scope_configuration ".firebase.app_id_android = \"$app_id\""

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ firebase.app_id_android '$app_id' is not a Firebase app id"
		assert_line "  💡 Possible causes:"
		assert_line "    • The value was copied with extra characters, or it is the app id of another platform"
		assert_line "  🔧 How to fix:"
		assert_line "    • Copy the android app id from the Firebase console (Project settings > Your apps): it looks like 1:1234567890:android:abcdef0123456789"
		[ ! -f "$AWS_MOCK_CALLS_LOG" ]
	done
}

@test "Should reject the ios app id with the android shape" {
	export PLATFORMS="android ios"
	with_scope_configuration '.firebase.app_id_ios = "1:726762523137:android:a700b1fa49f91e41eb0e00"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ firebase.app_id_ios '1:726762523137:android:a700b1fa49f91e41eb0e00' is not a Firebase app id"
}

@test "Should reject a Firebase project id with unexpected characters" {
	local project
	for project in "np-mobile-pc --token x" "NP_Mobile" "np-mobile-pc;rm" "np mobile"; do
		with_scope_configuration ".firebase.project = \"$project\""

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ firebase.project '$project' is not a Firebase project id"
		assert_line "  💡 Possible causes:"
		assert_line "    • The value is the project name or number instead of the project id"
		assert_line "  🔧 How to fix:"
		assert_line "    • Copy the project id from the Firebase console (Project settings > General): lowercase letters, digits and dashes only"
		[ ! -f "$AWS_MOCK_CALLS_LOG" ]
	done
}

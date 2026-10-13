#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/signing/keyvault/setup
#
# The layer reads the keystore secret named by android.keystore_secret from
# AWS Secrets Manager, signs the android binary with apksigner and exports
# SIGNED_BINARY_PATH_ANDROID. aws and apksigner are the mocks in
# tests/resources/mocks. Passwords must never reach the output.
#
# Run: bats mobile-store/deployment/tests/signing/keyvault/setup_test.bats
# =============================================================================

KEYSTORE_PASSWORD="st0re-s3cret-pw"
KEY_PASSWORD="k3y-s3cret-pw"

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/signing/keyvault/setup"

	export SIGNING_LAYER="keyvault"
	mkdir -p "$WORKDIR/android"
	cp "$AWS_MOCK_S3_OBJECT" "$WORKDIR/android/app.apk"
	export BINARY_PATH_ANDROID="$WORKDIR/android/app.apk"

	KEYSTORE_B64=$(printf 'fake-jks-bytes' | base64)
	write_mock_secret "mobile/android-keystore" "$(jq -nc \
		--arg ks "$KEYSTORE_B64" --arg kspw "$KEYSTORE_PASSWORD" --arg keypw "$KEY_PASSWORD" \
		'{keystore_base64: $ks, keystore_password: $kspw, key_alias: "release", key_password: $keypw}')"
}

teardown() {
	teardown_layer_test
}

@test "Should sign the android binary with the keystore from the secrets manager" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Signing layer 'keyvault': signing with the keystore stored in the secrets manager"
	assert_line "   📡 Reading secret 'mobile/android-keystore'"
	assert_line "   ✅ android: signed $WORKDIR/android/app.apk -> $WORKDIR/android/app-signed.apk (alias 'release')"
	assert_mock_call "$AWS_MOCK_CALLS_LOG" "aws secretsmanager get-secret-value --secret-id mobile/android-keystore --query SecretString --output text"
	assert_mock_call "$APKSIGNER_MOCK_LOG" "apksigner sign --ks $WORKDIR/android/keystore.jks --ks-pass env:MOBILE_STORE_KEYSTORE_PASSWORD --ks-key-alias release --key-pass env:MOBILE_STORE_KEY_PASSWORD --out $WORKDIR/android/app-signed.apk $WORKDIR/android/app.apk"
	assert_mock_call "$APKSIGNER_MOCK_LOG" "apksigner verify $WORKDIR/android/app-signed.apk"

	source "$SCRIPT"
	assert_equal "$SIGNED_BINARY_PATH_ANDROID" "$WORKDIR/android/app-signed.apk"
	assert_file_exists "$WORKDIR/android/app-signed.apk"
	assert_file_not_exists "$WORKDIR/android/keystore.jks"
}

@test "Should write the keystore with mode 600 and remove it even when the signing fails" {
	cat > "$TEST_TMP_DIR/apksigner" <<'EOF'
#!/bin/bash
stat -f '%Lp' "$WORKDIR/android/keystore.jks" 2>/dev/null > "$WORKDIR/keystore.mode" || stat -c '%a' "$WORKDIR/android/keystore.jks" > "$WORKDIR/keystore.mode"
cat "$WORKDIR/android/keystore.jks" > "$WORKDIR/keystore.copy"
exit 1
EOF
	chmod +x "$TEST_TMP_DIR/apksigner"
	export PATH="$TEST_TMP_DIR:$PATH"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_equal "$(cat "$WORKDIR/keystore.mode")" "600"
	assert_equal "$(cat "$WORKDIR/keystore.copy")" "fake-jks-bytes"
	assert_file_not_exists "$WORKDIR/android/keystore.jks"
}

@test "Should never print the passwords nor the secret" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	refute_output_contains "$KEYSTORE_PASSWORD"
	refute_output_contains "$KEY_PASSWORD"
	refute_output_contains "$KEYSTORE_B64"
	refute_output_contains "keystore_password"
	run cat "$APKSIGNER_MOCK_LOG"
	refute_output_contains "$KEYSTORE_PASSWORD"
	refute_output_contains "$KEY_PASSWORD"
}

@test "Should not print the passwords either when apksigner fails" {
	export APKSIGNER_MOCK_FAIL="sign"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ apksigner could not sign $WORKDIR/android/app.apk"
	assert_line "  💡 Possible causes:"
	assert_line "    • The keystore password, key alias or key password in secret 'mobile/android-keystore' is wrong"
	assert_line "    • The keystore_base64 field is not the base64 of a JKS/PKCS12 keystore"
	assert_line "  🔧 How to fix:"
	assert_line "    • Update secret 'mobile/android-keystore' with the keystore the Android app is released with"
	refute_output_contains "$KEYSTORE_PASSWORD"
	refute_output_contains "$KEY_PASSWORD"
}

@test "Should fail when the signature does not verify" {
	export APKSIGNER_MOCK_FAIL="verify"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The signature of $WORKDIR/android/app-signed.apk does not verify"
	assert_line "  💡 Possible causes:"
	assert_line "    • The input binary was already signed with a different scheme or is corrupted"
	assert_line "  🔧 How to fix:"
	assert_line "    • Make the CI upload an unsigned (or debug-signed) APK when the signing layer is keyvault"
}

@test "Should fail with the full troubleshooting block when the scope publishes ios" {
	export PLATFORMS="android ios"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ iOS signing with the keyvault layer is not implemented yet"
	assert_line "  💡 Possible causes:"
	assert_line "    • The scope publishes ios binaries and the scope configuration sets signing_layer to keyvault"
	assert_line "  🔧 How to fix:"
	assert_line "    • Use the prebuilt signing layer (sign in the CI) for scopes that publish ios until keyvault supports it"
	[ ! -f "$AWS_MOCK_CALLS_LOG" ]
}

@test "Should fail with the full troubleshooting block when apksigner is not installed" {
	mkdir -p "$TEST_TMP_DIR/bin"
	ln -s "$MOCKS_DIR/aws" "$TEST_TMP_DIR/bin/aws"
	export PATH="$TEST_TMP_DIR/bin:/usr/bin:/bin"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ apksigner is not available in the worker image"
	assert_line "  💡 Possible causes:"
	assert_line "    • The worker image was built without the Android build-tools"
	assert_line "  🔧 How to fix:"
	assert_line "    • Build the worker from an image that adds the Android build-tools (apksigner) and pin it in the agent"
}

@test "Should fail with the full troubleshooting block when android.keystore_secret is not set" {
	with_scope_configuration 'del(.android.keystore_secret)'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ android.keystore_secret is not set in the 'Mobile store' scope configuration"
	assert_line "  💡 Possible causes:"
	assert_line "    • The scope configuration sets signing_layer to keyvault but the Android section has no keystore secret"
	assert_line "  🔧 How to fix:"
	assert_line "    • Set android.keystore_secret to the name of the secret that holds the release keystore"
}

@test "Should fail with the full troubleshooting block when the secret cannot be read" {
	with_scope_configuration '.android.keystore_secret = "mobile/missing"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not read secret 'mobile/missing' from the secrets manager"
	assert_line "  💡 Possible causes:"
	assert_line "    • The secret does not exist in region us-east-1"
	assert_line "    • The agent role has no secretsmanager:GetSecretValue permission on it"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create the secret or grant the agent role read access to it"
}

@test "Should fail with the full troubleshooting block when the secret is malformed" {
	write_mock_secret "mobile/android-keystore" '{"keystore_base64":"Zm9v","key_alias":"release"}'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Secret 'mobile/android-keystore' is not a keystore secret"
	assert_line "  💡 Possible causes:"
	assert_line "    • The secret is not a JSON object with keystore_base64, keystore_password, key_alias and key_password"
	assert_line "  🔧 How to fix:"
	assert_line "    • Store the secret as {\"keystore_base64\": \"<base64 of the .jks>\", \"keystore_password\": \"...\", \"key_alias\": \"...\", \"key_password\": \"...\"}"
	refute_output_contains "Zm9v"
}

@test "Should fail when the android binary was not prepared" {
	unset BINARY_PATH_ANDROID

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ BINARY_PATH_ANDROID is not set"
	assert_line "    • The platform/android layer did not run before the signing layer"
}

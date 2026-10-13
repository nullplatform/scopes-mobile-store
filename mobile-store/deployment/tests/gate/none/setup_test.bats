#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/gate/none/setup
#
# No external approval: the layer only exports GATE_RESULT=approved.
#
# Run: bats mobile-store/deployment/tests/gate/none/setup_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/gate/none/setup"
}

teardown() {
	teardown_layer_test
}

@test "Should approve without an external gate" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Gate layer 'none'"
	assert_line "   ✅ No external approval required for channel 'internal'"

	source "$SCRIPT"
	assert_equal "$GATE_RESULT" "approved"
}

@test "Should name the channel of the scope" {
	export DISTRIBUTION_LAYER="firebase"
	export CHANNEL="production"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ No external approval required for channel 'production'"
}

# =============================================================================
# Policy: production on a public store needs the store review gate
# =============================================================================
@test "Should refuse production on a public store without the store review gate" {
	export CHANNEL="production"
	local layer
	for layer in app-store google-play; do
		export DISTRIBUTION_LAYER="$layer"
		unset GATE_RESULT

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Publishing to production on a public store requires gate_layer=store-review"
		assert_line "   📋 Channel: production | Distribution: $layer | Gate: none"
		assert_line "  💡 Possible causes:"
		assert_line "    • The 'Mobile store' scope configuration sets gate_layer to none for a scope that publishes to $layer"
		assert_line "  🔧 How to fix:"
		assert_line "    • Set gate_layer to store-review in the scope configuration of this namespace or dimension"
		assert_line "    • Or use the internal or testers channel, which do not reach the public store"
		refute_line "   ✅ No external approval required for channel 'production'"
	done

	source "$SCRIPT" || true
	assert_empty "${GATE_RESULT:-}" "GATE_RESULT"
}

@test "Should allow production without a gate on private distributions, with a warning" {
	export CHANNEL="production"
	local layer
	for layer in firebase foundry-eas intune; do
		export DISTRIBUTION_LAYER="$layer"

		run source "$SCRIPT"

		assert_equal "$status" "0"
		assert_line "   ⚠️ Publishing to production without an external approval gate"
		assert_line "   📋 Channel: production | Distribution: $layer | Gate: none (testers get the build as soon as it is uploaded)"
		assert_line "   ✅ No external approval required for channel 'production'"
	done
}

@test "Should allow internal and testers on a public store without a gate and without warnings" {
	local channel
	for channel in internal testers; do
		export CHANNEL="$channel"
		export DISTRIBUTION_LAYER="google-play"

		run source "$SCRIPT"

		assert_equal "$status" "0"
		assert_line "   ✅ No external approval required for channel '$channel'"
		refute_output_contains "⚠️"
	done
}

@test "Should refuse production when the distribution layer is unknown" {
	export CHANNEL="production"
	unset DISTRIBUTION_LAYER

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Cannot apply the production gate policy: DISTRIBUTION_LAYER is not set"
}

@test "Should refuse production with an unclassified distribution layer" {
	export CHANNEL="production"
	export DISTRIBUTION_LAYER="side-load"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unknown distribution layer 'side-load': cannot decide whether production needs an approval gate"
	assert_line "  🔧 How to fix:"
	assert_line "    • Add 'side-load' to validate_gate_for_channel in deployment/scripts/validators"
}

@test "Should apply the security validators whatever the channel and gate" {
	local validators="$DEPLOYMENT_DIR/scripts/validators"
	local channel gate
	for channel in internal testers production; do
		for gate in none store-review; do
			run bash -c "CHANNEL=$channel GATE_LAYER=$gate ASSETS_BUCKET=assets-aws-mobile; source '$validators'
				validate_scope_secret_name prod/x firebase.credentials_secret mobile/firebase-sa && exit 10
				validate_asset_url s3://other-bucket/app.apk && exit 11
				validate_firebase_project 'np mobile' && exit 12
				validate_firebase_app_id android 1:1:web:ab && exit 13
				exit 0"
			assert_equal "$status" "0"
		done
	done
}

#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/do_publish
#
# Runs deployment/distribution/$DISTRIBUTION_LAYER/publish, completes
# $WORKDIR/distribution.json with the channel and rollout, and records the
# summary on the deployment as a message (np deployment patch; the API has
# no metadata field on PATCH /deployment). np is the mock in
# tests/resources/mocks.
#
# Run: bats mobile-store/deployment/tests/scripts/do_publish_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_layer_test "$DEPLOYMENT_DIR"
	SCRIPT="$DEPLOYMENT_DIR/scripts/do_publish"

	# A fake distribution layer isolates the orchestration from Firebase.
	export SERVICE_PATH="$TEST_TMP_DIR/service"
	export DISTRIBUTION_LAYER="fake"
	mkdir -p "$SERVICE_PATH/deployment/distribution/fake"
	cat > "$SERVICE_PATH/deployment/distribution/fake/publish" <<'EOF'
#!/bin/bash
echo "fake publish for $PLATFORMS"
printf '{"provider":"fake","releases":{"android":{"name":"fake/release/1"}}}' > "$WORKDIR/distribution.json"
EOF
	chmod +x "$SERVICE_PATH/deployment/distribution/fake/publish"
}

teardown() {
	teardown_layer_test
}

patched_body() {
	grep -F "np deployment patch" "$NP_MOCK_CALLS_LOG" | sed 's/^np deployment patch --id 77 --body //; s/ --format json$//'
}

@test "Should run the publish script, complete distribution.json and record it on the deployment" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📝 Publishing through the 'fake' distribution layer..."
	assert_line "fake publish for android"
	assert_line "   📋 Distribution summary: {\"provider\":\"fake\",\"releases\":{\"android\":{\"name\":\"fake/release/1\"}},\"channel\":\"internal\",\"rollout_percentage\":5}"
	assert_line "   ✅ Recorded the distribution on deployment 77 (message MOBILE_STORE_DISTRIBUTION)"
	assert_line "✨ Publish complete"

	assert_json_equal "$(cat "$WORKDIR/distribution.json")" '{
		"provider": "fake",
		"releases": {"android": {"name": "fake/release/1"}},
		"channel": "internal",
		"rollout_percentage": 5
	}' "distribution.json"

	local body
	body=$(patched_body)
	assert_equal "$(echo "$body" | jq -r '.messages | length')" "1"
	assert_equal "$(echo "$body" | jq -r '.messages[0].level')" "INFO"
	assert_equal "$(echo "$body" | jq -r '.messages[0].code')" "MOBILE_STORE_DISTRIBUTION"
	assert_equal "$(echo "$body" | jq -r '.messages[0].timestamp | type')" "number"
	assert_equal "$(echo "$body" | jq -r '.messages[0].message')" 'mobile-store distribution: {"provider":"fake","releases":{"android":{"name":"fake/release/1"}},"channel":"internal","rollout_percentage":5}'
}

@test "Should keep the summary in distribution.json and warn when the deployment cannot be patched" {
	unset NP_MOCK_DEPLOYMENT_PATCH

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not record the distribution on deployment 77 (np deployment patch failed); the summary stays in $WORKDIR/distribution.json"
	assert_line "✨ Publish complete"
	assert_equal "$(jq -r '.channel' "$WORKDIR/distribution.json")" "internal"
}

@test "Should fail with the full troubleshooting block when the layer has no publish script" {
	export DISTRIBUTION_LAYER="intune"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The distribution layer 'intune' has no publish script"
	assert_line "  💡 Possible causes:"
	assert_line "    • 'intune' is not implemented yet, or the scope configuration names a distribution layer that does not exist"
	assert_line "    • The publish script does not exist at: $SERVICE_PATH/deployment/distribution/intune/publish"
	assert_line "  🔧 How to fix:"
	assert_line "    • Set distribution_layer in the 'Mobile store' scope configuration to an implementation under deployment/distribution/ that has a publish script"
	refute_np_called "deployment patch"
}

@test "Should propagate a publish failure without touching the deployment" {
	cat > "$SERVICE_PATH/deployment/distribution/fake/publish" <<'EOF'
#!/bin/bash
echo "   ❌ fake publish failed"
exit 1
EOF

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ fake publish failed"
	refute_line "✨ Publish complete"
	refute_np_called "deployment patch"
}

@test "Should fail when the publish script did not write distribution.json" {
	cat > "$SERVICE_PATH/deployment/distribution/fake/publish" <<'EOF'
#!/bin/bash
echo "published nothing"
EOF

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The 'fake' publish script did not write $WORKDIR/distribution.json"
	assert_line "  💡 Possible causes:"
	assert_line "    • The distribution layer does not follow the publish contract (write {provider, releases} to \$WORKDIR/distribution.json)"
	refute_np_called "deployment patch"
}

@test "Should reject a distribution layer name with path characters" {
	export DISTRIBUTION_LAYER="../fake"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid distribution implementation name '../fake': only lowercase letters, digits and dashes are allowed"
}

# =============================================================================
# Gate policy enforced before anything is distributed
# =============================================================================
@test "Should refuse to publish production to a public store when the gate is none" {
	export CHANNEL="production"
	export GATE_LAYER="none"
	export DISTRIBUTION_LAYER="google-play"
	mkdir -p "$SERVICE_PATH/deployment/distribution/google-play"
	cp "$SERVICE_PATH/deployment/distribution/fake/publish" "$SERVICE_PATH/deployment/distribution/google-play/publish"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Publishing to production on a public store requires gate_layer=store-review"
	assert_line "   📋 Channel: production | Distribution: google-play | Gate: none"
	assert_line "  💡 Possible causes:"
	assert_line "    • The 'Mobile store' scope configuration sets gate_layer to none for a scope that publishes to google-play"
	assert_line "  🔧 How to fix:"
	assert_line "    • Set gate_layer to store-review in the scope configuration of this namespace or dimension"
	assert_line "    • Or use the internal or testers channel, which do not reach the public store"
	refute_line "fake publish for android"
	refute_np_called "deployment patch"
}

@test "Should publish production to a public store when the gate is store-review" {
	export CHANNEL="production"
	export GATE_LAYER="store-review"
	export GATE_RESULT="approved"
	export DISTRIBUTION_LAYER="google-play"
	mkdir -p "$SERVICE_PATH/deployment/distribution/google-play"
	cp "$SERVICE_PATH/deployment/distribution/fake/publish" "$SERVICE_PATH/deployment/distribution/google-play/publish"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "fake publish for android"
	assert_line "✨ Publish complete"
}

@test "Should publish production through firebase without a gate, with a warning" {
	export CHANNEL="production"
	export GATE_LAYER="none"
	export DISTRIBUTION_LAYER="firebase"
	mkdir -p "$SERVICE_PATH/deployment/distribution/firebase"
	cp "$SERVICE_PATH/deployment/distribution/fake/publish" "$SERVICE_PATH/deployment/distribution/firebase/publish"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Publishing to production without an external approval gate"
	assert_line "   📋 Channel: production | Distribution: firebase | Gate: none (testers get the build as soon as it is uploaded)"
	assert_line "fake publish for android"
}

# =============================================================================
# Fail closed: only an explicit store-review gate that ran lets production
# reach a public store
# =============================================================================
setup_google_play() {
	export CHANNEL="production"
	export DISTRIBUTION_LAYER="google-play"
	mkdir -p "$SERVICE_PATH/deployment/distribution/google-play"
	cp "$SERVICE_PATH/deployment/distribution/fake/publish" "$SERVICE_PATH/deployment/distribution/google-play/publish"
}

@test "Should refuse production on a public store when the gate layer is empty or misspelled" {
	setup_google_play
	export GATE_RESULT="approved"
	local gate
	for gate in "" "store_review" "Store-Review" "none"; do
		export GATE_LAYER="$gate"

		run bash "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Publishing to production on a public store requires gate_layer=store-review"
		assert_line "   📋 Channel: production | Distribution: google-play | Gate: ${gate:-(not set)}"
		refute_line "fake publish for android"
	done
	refute_np_called "deployment patch"
}

@test "Should refuse to publish when the store-review gate did not approve" {
	setup_google_play
	export GATE_LAYER="store-review"
	local result
	for result in "" "pending" "rejected"; do
		export GATE_RESULT="$result"

		run bash "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ The 'store-review' gate has not approved this deployment (GATE_RESULT=${result:-(not set)})"
		assert_line "  💡 Possible causes:"
		assert_line "    • The gate layer did not run before the publish, or the approval is still pending or was rejected"
		assert_line "  🔧 How to fix:"
		assert_line "    • Run the deployment workflow from the start so the gate layer runs and approves before publishing"
		refute_line "fake publish for android"
	done
}

@test "Should refuse production with an unknown gate layer on a private distribution" {
	export CHANNEL="production"
	export DISTRIBUTION_LAYER="fake"
	export GATE_LAYER="nonee"
	export GATE_RESULT="approved"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unknown distribution layer 'fake': cannot decide whether production needs an approval gate"
}

@test "Should refuse an unknown channel" {
	export CHANNEL="beta"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unknown channel 'beta': cannot apply the approval gate policy"
}

@test "Should keep the rollout percentage the distribution layer reports" {
	cat > "$SERVICE_PATH/deployment/distribution/fake/publish" <<'EOF'
#!/bin/bash
printf '{"provider":"fake","rollout_percentage":100,"releases":{}}' > "$WORKDIR/distribution.json"
EOF

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_equal "$(jq -r '.rollout_percentage' "$WORKDIR/distribution.json")" "100"
}

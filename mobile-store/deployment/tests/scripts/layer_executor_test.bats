#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/layer_executor
#
# The executor runs $SERVICE_PATH/deployment/<LAYER_TYPE>/<impl>/setup where
# <impl> is the value of the variable named by LAYER_VAR. The tests point
# SERVICE_PATH at tests/resources/layers, which holds trivial setup scripts,
# so they do not depend on the real layers.
#
# Run: bats mobile-store/deployment/tests/scripts/layer_executor_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	SCOPE_DIR="$(cd "$DEPLOYMENT_DIR/.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	SCRIPT="$DEPLOYMENT_DIR/scripts/layer_executor"

	source "$PROJECT_ROOT/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"

	export SERVICE_PATH="$DEPLOYMENT_DIR/tests/resources/layers"
	unset LAYER_TYPE LAYER_VAR LAYER_CHECK SIGNING_LAYER DISTRIBUTION_LAYER GATE_LAYER
}

# =============================================================================
# Missing configuration
# =============================================================================
@test "Should fail when LAYER_TYPE is not set" {
	export LAYER_VAR="DISTRIBUTION_LAYER"
	export DISTRIBUTION_LAYER="firebase"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ LAYER_TYPE is not set"
	assert_line "  💡 Possible causes:"
	assert_line "    • The workflow step that runs layer_executor has no configuration.LAYER_TYPE"
	assert_line "  🔧 How to fix:"
	assert_line "    • Add LAYER_TYPE (signing, distribution or gate) to the workflow step configuration"
}

@test "Should fail when LAYER_VAR is not set" {
	export LAYER_TYPE="distribution"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ LAYER_VAR is not set"
	assert_line "  💡 Possible causes:"
	assert_line "    • The workflow step that runs layer_executor has no configuration.LAYER_VAR"
	assert_line "  🔧 How to fix:"
	assert_line "    • Add LAYER_VAR (SIGNING_LAYER, DISTRIBUTION_LAYER or GATE_LAYER) to the workflow step configuration"
}

@test "Should reject a LAYER_VAR that is not a variable name before expanding it" {
	export LAYER_TYPE="distribution"
	export DISTRIBUTION_LAYER="firebase"
	local value
	for value in "../x" "fire base" "distribution_layer" "DISTRIBUTION_LAYER[@]"; do
		export LAYER_VAR="$value"

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Invalid LAYER_VAR '$value': must be an environment variable name (uppercase letters, digits and underscores)"
		assert_line "  💡 Possible causes:"
		assert_line "    • The workflow step configuration sets LAYER_VAR to something that is not a variable name"
		assert_line "  🔧 How to fix:"
		assert_line "    • Set LAYER_VAR to the variable build_context exports for this layer (SIGNING_LAYER, DISTRIBUTION_LAYER or GATE_LAYER)"
		refute_line "setup executed for distribution/firebase"
	done
}

@test "Should fail with the full troubleshooting block when the layer variable has no value" {
	export LAYER_TYPE="signing"
	export LAYER_VAR="SIGNING_LAYER"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ SIGNING_LAYER is not set"
	assert_line "  💡 Possible causes:"
	assert_line "    • build_context did not resolve the signing layer"
	assert_line "    • The scope configuration is missing the signing layer"
	assert_line "  🔧 How to fix:"
	assert_line "    • Ensure the 'Mobile store' scope configuration has the signing layer configured"
}

# =============================================================================
# Unknown implementation
# =============================================================================
@test "Should fail when the implementation has no setup script" {
	export LAYER_TYPE="distribution"
	export LAYER_VAR="DISTRIBUTION_LAYER"
	export DISTRIBUTION_LAYER="foo"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unknown distribution implementation: 'foo'"
	assert_line "  💡 Possible causes:"
	assert_line "    • 'foo' is not a supported distribution"
	assert_line "    • The setup script does not exist at: $SERVICE_PATH/deployment/distribution/foo/setup"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check the available distribution implementations in deployment/distribution/"
}

# =============================================================================
# Execution
# =============================================================================
@test "Should execute the setup script of each layer type" {
	local layer_type layer_var impl
	for spec in "signing SIGNING_LAYER prebuilt" "distribution DISTRIBUTION_LAYER firebase" "gate GATE_LAYER none"; do
		read -r layer_type layer_var impl <<< "$spec"
		export LAYER_TYPE="$layer_type"
		export LAYER_VAR="$layer_var"
		export "$layer_var=$impl"

		run source "$SCRIPT"

		assert_equal "$status" "0"
		assert_line "📝 Running $layer_type layer '$impl'"
		assert_line "setup executed for $layer_type/$impl"
	done
}

@test "Should propagate a non-zero exit code from the setup script" {
	export LAYER_TYPE="distribution"
	export LAYER_VAR="DISTRIBUTION_LAYER"
	export DISTRIBUTION_LAYER="broken"
	mkdir -p "$BATS_TEST_TMPDIR/deployment/distribution/broken"
	printf '#!/bin/bash\necho "setup failed"\nexit 3\n' > "$BATS_TEST_TMPDIR/deployment/distribution/broken/setup"
	export SERVICE_PATH="$BATS_TEST_TMPDIR"

	run source "$SCRIPT"

	assert_equal "$status" "3"
	assert_line "setup failed"
}

@test "Should propagate variables set by the setup script (sourced, not a subprocess)" {
	export LAYER_TYPE="distribution"
	export LAYER_VAR="DISTRIBUTION_LAYER"
	export DISTRIBUTION_LAYER="exporter"
	mkdir -p "$BATS_TEST_TMPDIR/deployment/distribution/exporter"
	printf '#!/bin/bash\nexport DISTRIBUTION_URL="https://example.com/app"\n' > "$BATS_TEST_TMPDIR/deployment/distribution/exporter/setup"
	export SERVICE_PATH="$BATS_TEST_TMPDIR"

	source "$SCRIPT"

	assert_equal "$DISTRIBUTION_URL" "https://example.com/app"
}

# =============================================================================
# Check mode (LAYER_CHECK=true): validate the implementation without running it
# =============================================================================
@test "Should only validate the implementation when LAYER_CHECK is true" {
	export LAYER_TYPE="distribution"
	export LAYER_VAR="DISTRIBUTION_LAYER"
	export DISTRIBUTION_LAYER="firebase"
	export LAYER_CHECK="true"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ distribution implementation 'firebase' is available"
	refute_line "setup executed for distribution/firebase"
}

@test "Should fail in check mode when the implementation does not exist" {
	export LAYER_TYPE="distribution"
	export LAYER_VAR="DISTRIBUTION_LAYER"
	export DISTRIBUTION_LAYER="foo"
	export LAYER_CHECK="true"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unknown distribution implementation: 'foo'"
	assert_line "    • Check the available distribution implementations in deployment/distribution/"
}

@test "Should fail in check mode when LAYER_TYPE is not set" {
	export LAYER_VAR="DISTRIBUTION_LAYER"
	export DISTRIBUTION_LAYER="firebase"
	export LAYER_CHECK="true"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ LAYER_TYPE is not set"
}

@test "Should execute the setup script when LAYER_CHECK is anything but true" {
	export LAYER_TYPE="gate"
	export LAYER_VAR="GATE_LAYER"
	export GATE_LAYER="none"
	export LAYER_CHECK="false"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "setup executed for gate/none"
}

# =============================================================================
# Hardening: LAYER_TYPE and the implementation name become path segments
# =============================================================================
@test "Should reject a LAYER_TYPE with path characters" {
	export LAYER_TYPE="../scripts"
	export LAYER_VAR="DISTRIBUTION_LAYER"
	export DISTRIBUTION_LAYER="firebase"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid layer type '../scripts': only lowercase letters and underscores are allowed"
	assert_line "  💡 Possible causes:"
	assert_line "    • The workflow step configuration sets LAYER_TYPE to an unexpected value"
	assert_line "  🔧 How to fix:"
	assert_line "    • Use one of the layer directories under deployment/ (signing, distribution, gate)"
}

@test "Should reject an implementation name with path characters or spaces" {
	export LAYER_TYPE="distribution"
	export LAYER_VAR="DISTRIBUTION_LAYER"
	local value
	for value in "../../tests/resources/layers/deployment/distribution/firebase" "fire base" "Firebase"; do
		export DISTRIBUTION_LAYER="$value"

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Invalid distribution implementation name '$value': only lowercase letters, digits and dashes are allowed"
		assert_line "  💡 Possible causes:"
		assert_line "    • The scope configuration sets the distribution layer to an unexpected value"
		assert_line "  🔧 How to fix:"
		assert_line "    • Set the distribution layer in the 'Mobile store' scope configuration to one of the implementations under deployment/distribution/"
		refute_line "setup executed for distribution/firebase"
	done
}

@test "Should reject an invalid implementation name also in check mode" {
	export LAYER_TYPE="gate"
	export LAYER_VAR="GATE_LAYER"
	export GATE_LAYER="../none"
	export LAYER_CHECK="true"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid gate implementation name '../none': only lowercase letters, digits and dashes are allowed"
}

# =============================================================================
# Shared helpers for the mobile-store BATS tests, on top of testing/assertions.sh
#
# bats-assert is not a dependency of the test runner, so the line assertions
# live here. Both work on the `lines` array that `run` fills in.
# =============================================================================

# Assert that `run` produced exactly this line (whole line, whitespace included).
assert_line() {
	local expected="$1" line
	for line in "${lines[@]}"; do
		if [ "$line" = "$expected" ]; then
			return 0
		fi
	done
	echo "Expected line not found: '$expected'"
	echo "Output was:"
	echo "$output"
	return 1
}

# Assert that `run` did not produce this exact line.
refute_line() {
	local unexpected="$1" line
	for line in "${lines[@]}"; do
		if [ "$line" = "$unexpected" ]; then
			echo "Unexpected line found: '$unexpected'"
			echo "Output was:"
			echo "$output"
			return 1
		fi
	done
}

# Assert that the np mock was (or was not) invoked with a command containing the text.
assert_np_called() {
	local needle="$1"
	if ! grep -qF -- "$needle" "$NP_MOCK_CALLS_LOG" 2>/dev/null; then
		echo "Expected an np call containing: '$needle'"
		echo "np calls were:"
		cat "$NP_MOCK_CALLS_LOG" 2>/dev/null || echo "(none)"
		return 1
	fi
}

refute_np_called() {
	local needle="$1"
	if grep -qF -- "$needle" "$NP_MOCK_CALLS_LOG" 2>/dev/null; then
		echo "Did not expect an np call containing: '$needle'"
		echo "np calls were:"
		cat "$NP_MOCK_CALLS_LOG"
		return 1
	fi
}

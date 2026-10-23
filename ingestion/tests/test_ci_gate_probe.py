# Deliberately failing test: proves that a red PR can't be merged (phase 4 acceptance). This PR is
# closed without merging.


def test_ci_gate_blocks_a_failing_pr():
    raise AssertionError("deliberate failure to test branch protection")

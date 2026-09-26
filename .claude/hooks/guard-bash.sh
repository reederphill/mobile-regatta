#!/bin/bash
# PreToolUse hook for Bash: blocks the waiting patterns docs/agents/validation.md rules out. Exit 2 blocks the
# call and shows the message to the agent.
cmd=$(jq -r '.tool_input.command // empty')

block() {
    echo "Blocked by .claude/hooks/guard-bash.sh: $1" >&2
    exit 2
}

# Polling loops: a loop with sleep in it (or perl's select as a sleep).
if grep -Eq '\b(until|while|for)\b' <<<"$cmd" && grep -Eq '\bsleep\b|select\(undef' <<<"$cmd"; then
    block "no sleep polling loops. Run check.sh in the foreground with a timeout, or run_in_background and end your turn; the completion notification wakes you. See docs/agents/validation.md."
fi

# Waiting on any check.sh on the machine, including other agents' runs.
if grep -Eq 'pgrep[^|;&]*check\.sh' <<<"$cmd"; then
    block "pgrep -f check.sh matches every agent's check.sh, not just yours. Wait on your own run's notification."
fi

# UI tests run in CI only.
if grep -Eq '\bxcodebuild\b' <<<"$cmd" && grep -q 'RegattaUITests' <<<"$cmd" && ! grep -q 'ALLOW_LOCAL_UI_TESTS=1' <<<"$cmd"; then
    block "RegattaUITests run in CI only. If CI can't run and the ticket's acceptance needs one, the orchestrator (not an implementer) prefixes the command with ALLOW_LOCAL_UI_TESTS=1."
fi

exit 0

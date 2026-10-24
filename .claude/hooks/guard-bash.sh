#!/bin/bash
# PreToolUse hook for Bash: blocks sleep polling loops. Exit 2 blocks the call and shows the message to the agent.
cmd=$(jq -r '.tool_input.command // empty')

if grep -Eq '\b(until|while|for)\b' <<<"$cmd" && grep -Eq '\bsleep\b|select\(undef' <<<"$cmd"; then
    echo "Blocked by .claude/hooks/guard-bash.sh: no sleep polling loops. Run the command in the foreground with a timeout, or run_in_background and end your turn; the completion notification wakes you." >&2
    exit 2
fi

exit 0

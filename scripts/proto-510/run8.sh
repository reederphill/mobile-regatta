#!/bin/zsh
# run8.sh <name> <variant|-> [ENV=VAL ...]   80 races: 8 boats, 2 laps, seeds 8 (the quick look)
S="/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/24f01bcb-68c7-491d-894d-6a1acd07cc0e/scratchpad/r510"
cd /Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t510
name=$1; v=$2; shift 2
[[ $v == - ]] && v=""
env REGATTA_BOT_VARIANT="$v" REGATTA_GATE_DUMP=-9999 "$@" scripts/heavy.sh .build/check/RegattaCore/release/regatta-botsuite --profile-mix live --tier-mix mixed --fleet-size 8 --laps 2 --seeds 8 --diagnose > $S/$name.txt 2> $S/$name.err

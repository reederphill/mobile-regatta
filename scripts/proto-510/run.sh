#!/bin/zsh
# run.sh <name> <variant letters or -> [ENV=VAL ...]   (320 races: every fleet size of the matrix, 2 laps, seeds 8)
S="/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/24f01bcb-68c7-491d-894d-6a1acd07cc0e/scratchpad/r510"
cd /Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t510
name=$1; v=$2; shift 2
[[ $v == - ]] && v=""
env REGATTA_BOT_VARIANT="$v" REGATTA_GATE_DUMP=-9999 "$@" scripts/heavy.sh .build/check/RegattaCore/release/regatta-botsuite --profile-mix live --tier-mix mixed --laps 2 --seeds 8 --diagnose > $S/$name.txt 2> $S/$name.err
echo "exit $? $name"; head -1 $S/$name.txt

#!/bin/zsh
# trace.sh <variant> <venue:conditions:seed:fleet> <out>   one race with the gate trace
S="/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/24f01bcb-68c7-491d-894d-6a1acd07cc0e/scratchpad/r510"
cd /Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t510
v=$1; [[ $v == - ]] && v=""
f=${2##*:}
REGATTA_BOT_VARIANT="$v" REGATTA_GATE_TRACE=1 REGATTA_GATE_DUMP=0 REGATTA_ONLY=$2 scripts/heavy.sh .build/check/RegattaCore/release/regatta-botsuite --profile-mix live --tier-mix mixed --fleet-size $f --laps 2 --seeds 8 --diagnose > $S/$3.txt 2> $S/$3.err
grep '^GD' $S/$3.err

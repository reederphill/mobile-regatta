#!/bin/bash
# run.sh <base|branch> <name> <args...>
S=/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/3adba75f-7414-427a-9f0f-804289e69562/scratchpad/525-1
w=$1; n=$2; shift 2
cd /Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t525-1
/usr/bin/time -p scripts/heavy.sh $S/$w-botsuite "$@" --json $S/out/$n-$w.json > $S/out/$n-$w.txt 2> $S/out/$n-$w.err
echo "$w $n exit $?"; tail -3 $S/out/$n-$w.err

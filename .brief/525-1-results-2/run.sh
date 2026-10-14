#!/bin/bash
# run.sh <bin: base|head> <outfile-stem> <args...>
P=/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/3adba75f-7414-427a-9f0f-804289e69562/scratchpad
R=$P/525-1r2
w=$1; n=$2; shift 2
case $w in base) B=$P/525-1/base-botsuite;; head) B=$R/head-botsuite;; esac
cd /Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t525-1
/usr/bin/time -p scripts/heavy.sh $B "$@" --json $R/$n.json > $R/$n.txt 2> $R/$n.err
echo "$w $n exit $?"; tail -3 $R/$n.err

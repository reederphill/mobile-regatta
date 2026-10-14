#!/bin/bash
# sweep.sh <tag>
S=/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/3adba75f-7414-427a-9f0f-804289e69562/scratchpad; B=.build/check/RegattaCore/release/regatta-botsuite; t=$1
cd /Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t525-1
for set in "m8|--tier-mix mixed --fleet-size 8 --seeds 8" "m8n|--tier-mix mixed --fleet-size 8 --matrix $S/525-1/matrix-s9-16.json" "club8|--tier-mix club --fleet-size 8 --seeds 8"; do
 n=${set%%|*}; a=${set#*|}
 scripts/heavy.sh $B --profile-mix live --laps 2 --diagnose $a --json $S/r3/out/$n-$t.json > $S/r3/out/$n-$t.txt 2>/dev/null
 for f in $S/525-1/out/$n-base $S/525-1r2/out/$n-branch $S/r3/out/$n-$t; do printf "%-10s %-14s " $n $(basename $f); grep -E "^ +(all|club) +gate" $f.txt | grep -E "^ +$( [ $n = club8 ] && echo club || echo all) " | awk '{print "mean",$4,"deep",$(NF-4),"p90",$(NF-3),"still",$(NF-1),$NF}'; done
done

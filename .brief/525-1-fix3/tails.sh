#!/bin/bash
# tails.sh <tag>
cd /Users/phill/Documents/git/mobile-regatta/.claude/worktrees/t525-1
for set in "m8|--tier-mix mixed --fleet-size 8 --seeds 8" "m8n|--tier-mix mixed --fleet-size 8 --matrix /private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/3adba75f-7414-427a-9f0f-804289e69562/scratchpad/525-1/matrix-s9-16.json" "club8|--tier-mix club --fleet-size 8 --seeds 8" "nat16|--tier-mix national --fleet-size 16 --seeds 16"; do
 n=${set%%|*}
 TRACE_CELLS=all TRACE_ARGS="${set#*|}" TRACE_OUT=/private/tmp/claude-501/-Users-phill-Documents-git-mobile-regatta/3adba75f-7414-427a-9f0f-804289e69562/scratchpad/r3/tails-$n-$1.txt scripts/heavy.sh swift test --skip-build --filter TmpGateTrace --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore -Xswiftc -O 2>&1 | tail -1
done

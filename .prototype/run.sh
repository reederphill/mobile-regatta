#!/usr/bin/env bash
# .prototype/run.sh <name> <variant letters or ""> <botsuite args...>   (env passes through: REGATTA_SEED_START etc.)
# Sails the release binary, output to .prototype/results/<name>.{txt,err}. Heavy: goes through scripts/heavy.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
name=$1; variant=$2; shift 2
REGATTA_BOT_VARIANT="$variant" REGATTA_PACK_DUMP=1 REGATTA_GATE_DUMP=-9999 \
  scripts/heavy.sh .build/check/RegattaCore/release/regatta-botsuite --profile-mix live --laps 2 --diagnose "$@" \
  > .prototype/results/$name.txt 2> .prototype/results/$name.err || true
python3 .prototype/sum.py $name

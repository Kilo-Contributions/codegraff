#!/bin/bash
# Clef compaction experiment driver: 5 arms x N trials on deepseek-v4-flash
# via the codegraff gateway at a forced-low compaction threshold (10k tokens,
# GRAFF_COMPACT_PCT=1 on the 1M window). Shape cloned from evals/compact_ab.
#
# Each run is ONE session fed 13 turns on stdin (see gen_turns.py): 6 files x
# (anchor turn + verbatim-context turn), then the answer turn. Multi-turn is
# load-bearing: a single-prompt tool loop never compacts more than once (the
# unresolved opening user message pins history via compact_cut pin_degrade),
# while the between-turns gate compacts every turn over threshold.
#
# Corpus + turns live in $B (default /tmp/clef_exp); generate with
# gen_corpus.py then gen_turns.py. GRAFF_TOOL_HANDLE_BYTES=1MB keeps every
# read inline (no handle paging), so per-turn 40KB send-time stubs plus
# assistant verbatim quotes accumulate history deterministically.
#
# Arms (deepseek is chat-wire, so the old server arm is inert here):
#   clef   : gateway /v1/compact prune (GRAFF_CLEF_COMPACT=1; default off, ADR 0261)
#   client : classic single-pass summary (GRAFF_CLEF_COMPACT=0)
#   mix    : two-pass extract+synthesis summary (GRAFF_COMPACT_MIX=1 + CLEF=0)
#   clefmix: clef prune, summary fallback WITH mix (both knobs on)
#   clefarc: clef prune in archive mode (GRAFF_CLEF_ARCHIVE=1): calls stay,
#            pruned outputs become a stub + artifact path instead of deleted
#   none   : no compaction baseline (PCT=100, CLEF=0)
set -u
B=${CLEF_EXP_DIR:-/tmp/clef_exp}
GRAFF=${GRAFF_BIN:-$HOME/codegraff/zig-out/bin/graff}
MODEL=${CLEF_MODEL:-deepseek-v4-flash}
TRIAL_TAG=${CLEF_TRIAL:-1}
mkdir -p $B/runs

run_one() {
  local arm=$1 trial=$2
  local d=$B/runs/${MODEL##*/}-${arm}${trial}
  rm -rf "$d"; mkdir -p "$d"; cp -r $B/src "$d"/
  local envs="GRAFF_TOOL_HANDLE_BYTES=1048576 GRAFF_COMPACT_PCT=1 GRAFF_SERVER_COMPACT=0"
  case $arm in
    clef)    envs="$envs GRAFF_CLEF_COMPACT=1";;                   # default is off (ADR 0261)
    client)  envs="$envs GRAFF_CLEF_COMPACT=0";;
    mix)     envs="$envs GRAFF_CLEF_COMPACT=0 GRAFF_COMPACT_MIX=1";;
    clefmix) envs="$envs GRAFF_CLEF_COMPACT=1 GRAFF_COMPACT_MIX=1";; # clef first, mix summary on noop
    clefarc) envs="$envs GRAFF_CLEF_COMPACT=1 GRAFF_CLEF_ARCHIVE=1";; # clef prune, archive instead of delete
    none)    envs="GRAFF_TOOL_HANDLE_BYTES=1048576 GRAFF_COMPACT_PCT=100 GRAFF_SERVER_COMPACT=0 GRAFF_CLEF_COMPACT=0";;
  esac
  echo "== ${arm}${trial} start $(date +%H:%M:%S)"
  local t0=$(date +%s)
  (cd "$d" && env $envs "$GRAFF" --yolo --new --model $MODEL < $B/turns.txt > out.log 2>&1)
  local rc=$?
  echo "$(( $(date +%s) - t0 ))" > "$d/wall_seconds"
  echo "== ${arm}${trial} exit=$rc wall=$(cat $d/wall_seconds)s"
}

if [ "${1:-}" = "wave" ]; then
  # one trial per arm in parallel (wave $2)
  run_one clef "$2" & run_one client "$2" & run_one mix "$2" & run_one clefmix "$2" & run_one none "$2" & wait
elif [ "${1:-}" = "arc" ]; then
  # archive-vs-delete: clef (delete) vs clefarc (archive) vs none baseline
  run_one clef "$2" & run_one clefarc "$2" & run_one none "$2" & wait
elif [ "${1:-}" = "recall" ]; then
  # recall variant (gen_recall.py, CLEF_EXP_DIR=/tmp/clef_recall): facts only
  # in deleted-after-read tool output; does each arm still know them?
  run_one client "$2" & run_one clef "$2" & run_one clefarc "$2" & run_one none "$2" & wait
elif [ "${1:-}" = "trio" ]; then
  # cross-model shape: clef/client/none only (mix arms already priced on
  # deepseek; the question here is prune-vs-summary-vs-nothing per model)
  run_one clef "$2" & run_one client "$2" & run_one none "$2" & wait
else
  for trial in 1 2; do
    for arm in clef client mix clefmix none; do
      run_one $arm $trial
    done
  done
fi
echo "ALL DONE"

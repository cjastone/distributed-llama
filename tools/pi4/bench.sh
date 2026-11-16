#!/usr/bin/env bash
# Single benchmark run for a distributed-llama cluster; appends one CSV row.
# Measures prefill (evaluation) and decode (prediction) tok/s separately via
# the built-in `dllama inference` benchmark output, plus RSS, temperature,
# throttle flags and eth0 byte counters on this (root) node.
#
# Verbose by default: prints the full configuration, streams dllama's output
# live, and samples memory/swap/temperature every SAMPLE_SEC seconds so a
# memory-feasibility problem (swap growth) is visible while it happens.
# Use -Q for the old quiet behavior (summary line only).
set -u

LABEL="run"
MODEL=""
TOKENIZER=""
WORKERS=""
STEPS=128
PROMPT="Continue this story: Once upon a time"
OUT="results.csv"
NTHREADS=4
MAXSEQLEN=4096
NBATCHES=8
EXTRA_ARGS=""
VERBOSE=1
SAMPLE_SEC="${SAMPLE_SEC:-10}"
DLLAMA="$(dirname "$0")/../../dllama"

usage() {
    echo "Usage: $0 -l <label> -m <model> -t <tokenizer> [-w \"host:port ...\"]"
    echo "          [-s <steps>] [-p <prompt>] [-o <out.csv>] [-n <nthreads>]"
    echo "          [-q <max-seq-len>] [-b <nbatches>] [-e <extra dllama args>] [-Q]"
    echo "  -Q  quiet: do not stream dllama output or print progress samples"
    echo "  SAMPLE_SEC=<n> env var sets the memory sampling interval (default 10)"
    exit 1
}

while getopts "l:m:t:w:s:p:o:n:q:b:e:Qh" opt; do
    case $opt in
        l) LABEL="$OPTARG";;
        m) MODEL="$OPTARG";;
        t) TOKENIZER="$OPTARG";;
        w) WORKERS="$OPTARG";;
        s) STEPS="$OPTARG";;
        p) PROMPT="$OPTARG";;
        o) OUT="$OPTARG";;
        n) NTHREADS="$OPTARG";;
        q) MAXSEQLEN="$OPTARG";;
        b) NBATCHES="$OPTARG";;
        e) EXTRA_ARGS="$OPTARG";;
        Q) VERBOSE=0;;
        *) usage;;
    esac
done
[ -z "$MODEL" ] || [ -z "$TOKENIZER" ] && usage
[ -x "$DLLAMA" ] || { echo "dllama binary not found at $DLLAMA (build it first)"; exit 1; }
[ -x /usr/bin/time ] || { echo "/usr/bin/time not found (needed for RSS): sudo apt install -y time"; exit 1; }
[ -f "$MODEL" ] || { echo "model not found: $MODEL"; exit 1; }
[ -f "$TOKENIZER" ] || { echo "tokenizer not found: $TOKENIZER"; exit 1; }

say() {
    [ "$VERBOSE" = "1" ] && echo "[bench $(date +%H:%M:%S)] $*" >&2
    return 0
}

read_eth_bytes() {
    awk '/eth0:/ {print $2, $10}' /proc/net/dev
}
read_temp() {
    if command -v vcgencmd > /dev/null 2>&1; then
        vcgencmd measure_temp | tr -dc '0-9.'
    else
        awk '{printf "%.1f", $1 / 1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "NA"
    fi
}
read_throttled() {
    command -v vcgencmd > /dev/null 2>&1 && vcgencmd get_throttled | cut -d= -f2 || echo "NA"
}
# prints: used_mb avail_mb swap_used_mb
read_mem() {
    free -m | awk '/^Mem:/{u=$3; a=$7} /^Swap:/{s=$3} END{print u+0, a+0, s+0}'
}

GIT_SHA=$(git -C "$(dirname "$0")/../.." rev-parse --short HEAD 2>/dev/null || echo "NA")
GIT_DIRTY=$(git -C "$(dirname "$0")/../.." status --porcelain 2>/dev/null | grep -qv '^??' && echo "+dirty" || echo "")
TEMP_BEFORE=$(read_temp)
THROTTLED_BEFORE=$(read_throttled)
read RX_BEFORE TX_BEFORE <<< "$(read_eth_bytes)"
[ -z "${RX_BEFORE:-}" ] && { RX_BEFORE=0; TX_BEFORE=0; }

WORKER_ARGS=""
[ -n "$WORKERS" ] && WORKER_ARGS="--workers $WORKERS"

LOG=$(mktemp)
SAMPLES=$(mktemp)

CMD=("$DLLAMA" inference
    --model "$MODEL" --tokenizer "$TOKENIZER"
    --buffer-float-type q80 --nthreads "$NTHREADS"
    --max-seq-len "$MAXSEQLEN" --nbatches "$NBATCHES"
    --steps "$STEPS" --temperature 0 --seed 12345
    --prompt "$PROMPT")
# shellcheck disable=SC2206
[ -n "$WORKER_ARGS" ] && CMD+=($WORKER_ARGS)
# shellcheck disable=SC2206
[ -n "$EXTRA_ARGS" ] && CMD+=($EXTRA_ARGS)

if [ "$VERBOSE" = "1" ]; then
    {
        echo "==================== bench: $LABEL ===================="
        echo "git:          $GIT_SHA$GIT_DIRTY"
        echo "binary:       $DLLAMA ($(stat -c %y "$DLLAMA" 2>/dev/null | cut -d. -f1))"
        echo "model:        $MODEL ($(du -h "$MODEL" | cut -f1))"
        echo "tokenizer:    $TOKENIZER"
        echo "workers:      ${WORKERS:-none (single node)}"
        echo "steps:        $STEPS   nthreads: $NTHREADS   max-seq-len: $MAXSEQLEN   nbatches: $NBATCHES"
        echo "prompt:       $PROMPT"
        echo "extra args:   ${EXTRA_ARGS:-none}"
        echo "output csv:   $OUT"
        echo "log file:     $LOG"
        echo "governor:     $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA)"
        echo "memlock:      $(ulimit -l)"
        echo "temp/throttle: ${TEMP_BEFORE} C / ${THROTTLED_BEFORE}"
        echo "memory (MB):  used/avail/swap-used = $(read_mem)"
        echo "command:      /usr/bin/time -v ${CMD[*]}"
        echo "======================================================"
    } >&2
    if [ -n "$WORKERS" ]; then
        for w in $WORKERS; do
            host=${w%%:*}; port=${w##*:}
            if timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
                say "worker $w: reachable"
            else
                say "worker $w: NOT reachable (is 'dllama worker --port $port --nthreads $NTHREADS' running?)"
            fi
        done
    fi
fi

# Background sampler: memory, swap, temperature, throttle. Writes to a file
# (for the CSV) and, when verbose, to the terminal.
(
    while true; do
        read -r M_USED M_AVAIL M_SWAP <<< "$(read_mem)"
        T=$(read_temp); TH=$(read_throttled)
        echo "$M_USED $M_AVAIL $M_SWAP $T $TH" >> "$SAMPLES"
        say "mem used ${M_USED} MB, avail ${M_AVAIL} MB, swap ${M_SWAP} MB | ${T} C | throttled ${TH}"
        sleep "$SAMPLE_SEC"
    done
) &
SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT INT TERM

say "starting run (first run spends minutes loading weights and sending them to workers)"
START_EPOCH=$(date +%s)
if [ "$VERBOSE" = "1" ]; then
    /usr/bin/time -v "${CMD[@]}" 2>&1 | tee "$LOG"
    EXIT_CODE=${PIPESTATUS[0]}
else
    /usr/bin/time -v "${CMD[@]}" > "$LOG" 2>&1
    EXIT_CODE=$?
fi
ELAPSED=$(( $(date +%s) - START_EPOCH ))

kill $SAMPLER_PID 2>/dev/null
wait $SAMPLER_PID 2>/dev/null

TEMP_AFTER=$(read_temp)
THROTTLED_AFTER=$(read_throttled)
read RX_AFTER TX_AFTER <<< "$(read_eth_bytes)"
[ -z "${RX_AFTER:-}" ] && { RX_AFTER=0; TX_AFTER=0; }

# Parse the dllama benchmark summary.
EVAL_TPS=$(awk '/^Evaluation/{f=1} f && /tokens\/s:/{print $2; exit}' "$LOG")
PRED_TPS=$(awk '/^Prediction/{f=1} f && /tokens\/s:/{print $2; exit}' "$LOG")
MAX_RSS_KB=$(awk -F: '/Maximum resident set size/{gsub(/ /,"",$2); print $2}' "$LOG")

# Output hash for bit-exactness checks: hash only the generated token text, never
# the timing/byte-count fields (those differ on every run).
if grep -q '^🔶 Pred' "$LOG"; then
    SHA256=$(sed -n 's/^🔶 Pred.* | //p' "$LOG" | sha256sum | cut -c1-16)
else
    # speculative mode prints raw pieces before the "Prediction" summary
    SHA256=$(awk '/^Prediction/{exit} {print}' "$LOG" | sha256sum | cut -c1-16)
fi

# Peak memory pressure observed by the sampler on this node.
MIN_AVAIL_MB=$(awk 'NR==1||$2<m{m=$2} END{print m+0}' "$SAMPLES")
MAX_SWAP_MB=$(awk '$3>m{m=$3} END{print m+0}' "$SAMPLES")
MAX_TEMP=$(awk '$4>m{m=$4} END{print m+0}' "$SAMPLES")

if [ ! -f "$OUT" ]; then
    echo "timestamp,label,git_sha,exit,eval_tps,pred_tps,max_rss_kb,temp_before,temp_after,throttled_before,throttled_after,rx_bytes,tx_bytes,steps,nthreads,max_seq_len,nbatches,output_hash,elapsed_s,min_avail_mb,max_swap_mb,max_temp" > "$OUT"
fi
echo "$(date -Iseconds),$LABEL,$GIT_SHA$GIT_DIRTY,$EXIT_CODE,${EVAL_TPS:-NA},${PRED_TPS:-NA},${MAX_RSS_KB:-NA},$TEMP_BEFORE,$TEMP_AFTER,$THROTTLED_BEFORE,$THROTTLED_AFTER,$((RX_AFTER - RX_BEFORE)),$((TX_AFTER - TX_BEFORE)),$STEPS,$NTHREADS,$MAXSEQLEN,$NBATCHES,$SHA256,$ELAPSED,$MIN_AVAIL_MB,$MAX_SWAP_MB,$MAX_TEMP" >> "$OUT"

if [ "$VERBOSE" = "1" ]; then
    {
        echo "==================== result: $LABEL ===================="
        echo "exit code:        $EXIT_CODE   (elapsed ${ELAPSED}s)"
        echo "prefill tok/s:    ${EVAL_TPS:-NA}"
        echo "decode tok/s:     ${PRED_TPS:-NA}"
        echo "root max RSS:     ${MAX_RSS_KB:-NA} kB"
        echo "root min avail:   ${MIN_AVAIL_MB} MB   peak swap: ${MAX_SWAP_MB} MB   $( [ "$MAX_SWAP_MB" -gt 0 ] 2>/dev/null && echo '<-- SWAP USED: model may not fit' )"
        echo "temp:             ${TEMP_BEFORE} -> ${TEMP_AFTER} C (peak ${MAX_TEMP})"
        echo "throttled:        ${THROTTLED_BEFORE} -> ${THROTTLED_AFTER}   $( [ "${THROTTLED_AFTER}" != "0x0" ] && [ "${THROTTLED_AFTER}" != "NA" ] && echo '<-- THROTTLING: result unreliable' )"
        echo "net (root eth0):  rx $((RX_AFTER - RX_BEFORE)) B, tx $((TX_AFTER - TX_BEFORE)) B"
        echo "output hash:      $SHA256"
        echo "csv row appended: $OUT"
        echo "======================================================"
    } >&2
    if [ "$EXIT_CODE" != "0" ]; then
        echo "[bench] dllama FAILED (exit $EXIT_CODE); last 20 log lines:" >&2
        tail -n 20 "$LOG" >&2
    fi
fi

echo "--- $LABEL: eval ${EVAL_TPS:-NA} tok/s, pred ${PRED_TPS:-NA} tok/s, rss ${MAX_RSS_KB:-NA} kB, temp $TEMP_BEFORE -> $TEMP_AFTER C (log: $LOG)"
rm -f "$SAMPLES"
exit $EXIT_CODE

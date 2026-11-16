#!/usr/bin/env bash
# Single benchmark run for a distributed-llama cluster; appends one CSV row.
# Measures prefill (evaluation) and decode (prediction) tok/s separately via
# the built-in `dllama inference` benchmark output, plus RSS, temperature,
# throttle flags and eth0 byte counters on this (root) node.
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
DLLAMA="$(dirname "$0")/../../dllama"

usage() {
    echo "Usage: $0 -l <label> -m <model> -t <tokenizer> [-w \"host:port ...\"]"
    echo "          [-s <steps>] [-p <prompt>] [-o <out.csv>] [-n <nthreads>]"
    echo "          [-q <max-seq-len>] [-b <nbatches>] [-e <extra dllama args>]"
    exit 1
}

while getopts "l:m:t:w:s:p:o:n:q:b:e:h" opt; do
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
        *) usage;;
    esac
done
[ -z "$MODEL" ] || [ -z "$TOKENIZER" ] && usage
[ -x "$DLLAMA" ] || { echo "dllama binary not found at $DLLAMA (build it first)"; exit 1; }

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

GIT_SHA=$(git -C "$(dirname "$0")/../.." rev-parse --short HEAD 2>/dev/null || echo "NA")
TEMP_BEFORE=$(read_temp)
THROTTLED_BEFORE=$(read_throttled)
read RX_BEFORE TX_BEFORE <<< "$(read_eth_bytes)"
[ -z "${RX_BEFORE:-}" ] && { RX_BEFORE=0; TX_BEFORE=0; }

WORKER_ARGS=""
[ -n "$WORKERS" ] && WORKER_ARGS="--workers $WORKERS"

LOG=$(mktemp)
/usr/bin/time -v "$DLLAMA" inference \
    --model "$MODEL" --tokenizer "$TOKENIZER" \
    --buffer-float-type q80 --nthreads "$NTHREADS" \
    --max-seq-len "$MAXSEQLEN" --nbatches "$NBATCHES" \
    --steps "$STEPS" --temperature 0 --seed 12345 \
    --prompt "$PROMPT" $WORKER_ARGS $EXTRA_ARGS > "$LOG" 2>&1
EXIT_CODE=$?

TEMP_AFTER=$(read_temp)
THROTTLED_AFTER=$(read_throttled)
read RX_AFTER TX_AFTER <<< "$(read_eth_bytes)"
[ -z "${RX_AFTER:-}" ] && { RX_AFTER=0; TX_AFTER=0; }

# Parse the dllama benchmark summary.
EVAL_TPS=$(awk '/^Evaluation/{f=1} f && /tokens\/s:/{print $2; exit}' "$LOG")
PRED_TPS=$(awk '/^Prediction/{f=1} f && /tokens\/s:/{print $2; exit}' "$LOG")
MAX_RSS_KB=$(awk -F: '/Maximum resident set size/{gsub(/ /,"",$2); print $2}' "$LOG")
SHA256=$(awk '/^Prediction/{exit} {print}' "$LOG" | sha256sum | cut -c1-16)

if [ ! -f "$OUT" ]; then
    echo "timestamp,label,git_sha,exit,eval_tps,pred_tps,max_rss_kb,temp_before,temp_after,throttled_before,throttled_after,rx_bytes,tx_bytes,steps,nthreads,max_seq_len,nbatches,output_hash" > "$OUT"
fi
echo "$(date -Iseconds),$LABEL,$GIT_SHA,$EXIT_CODE,${EVAL_TPS:-NA},${PRED_TPS:-NA},${MAX_RSS_KB:-NA},$TEMP_BEFORE,$TEMP_AFTER,$THROTTLED_BEFORE,$THROTTLED_AFTER,$((RX_AFTER - RX_BEFORE)),$((TX_AFTER - TX_BEFORE)),$STEPS,$NTHREADS,$MAXSEQLEN,$NBATCHES,$SHA256" >> "$OUT"

echo "--- $LABEL: eval ${EVAL_TPS:-NA} tok/s, pred ${PRED_TPS:-NA} tok/s, rss ${MAX_RSS_KB:-NA} kB, temp $TEMP_BEFORE -> $TEMP_AFTER C (log: $LOG)"
exit $EXIT_CODE

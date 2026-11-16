# Pi 4 cluster tuning kit

Tooling for benchmarking and tuning distributed-llama on a 4× Raspberry Pi 4
(8GB, Cortex-A72, Gigabit Ethernet) cluster. Everything here is optional and
changes nothing unless explicitly used.

## Build gates

The default `make` build is identical to stock distributed-llama. Each
optimization is an independent opt-in make variable so it can be A/B tested:

| Variable | Effect |
|---|---|
| `DL_ATOMIC_OPT=1` | Cache-line-padded barrier atomics + acquire/release ordering |
| `DL_PERSISTENT_POOL=1` | Persistent worker threads (no pthread_create per token) |
| `DL_WFE=1` | WFE/SEV low-power inter-step barrier (ARM; PAUSE on x86) |
| `DL_CHUNK_SIZE=16384` | Network transfer chunk size in bytes (default 4096) |
| `DL_SOCK_BUF=8388608` | SO_RCVBUF/SO_SNDBUF request per socket |
| `DL_BUSY_POLL=50` | SO_BUSY_POLL microseconds (Linux) |
| `DL_SOCK_PRIORITY=6` | SO_PRIORITY (Linux) |
| `DL_FUSE_SILU_MUL=1` | Fused SILU+MUL FFN op (CPU only, bit-exact) |
| `DL_MM_PREFETCH=4` | Software prefetch distance (blocks) in the non-dotprod NEON matmul |
| `DL_MM_UNROLL4=1` | 4-block unroll of the non-dotprod NEON matmul (not bit-identical) |
| `DL_LTO=1` / `DL_UNROLL=1` / `DL_ALIGN64=1` | -flto / -funroll-loops / -falign-*=64 |

Example full build:

```
make dllama dllama-api DL_ATOMIC_OPT=1 DL_PERSISTENT_POOL=1 DL_WFE=1 \
    DL_CHUNK_SIZE=16384 DL_FUSE_SILU_MUL=1
```

Runtime flags worth setting on a Pi 4 cluster (root and workers):
`--nthreads 4`, `--buffer-float-type q80`, `--max-seq-len 4096` (or as memory
allows), `--nbatches 8`. Optional: `--spec-ngram 8` for greedy CLI generation.

All nodes should run the same binary/gates. (`DL_FUSE_SILU_MUL` only changes
the graph built on the root, and the op itself is always compiled, so a
gate-on root does work with gate-off workers built from the same source.)

## Memory feasibility check (8GB nodes)

Before benchmarking a model, start the root once and read the printed
required-memory figures, then watch `free -m` and `vmstat 1` on the root and
one worker during a short run. There must be no swap activity after warmup.
If the root cannot hold the model at the chosen `--max-seq-len`, reduce it or
pick a smaller model. `--nbatches` also scales root memory (logits buffer is
nBatches × vocabSize × 4 bytes).

Raise the memlock limit so buffer mlock() succeeds (the binary warns if not):
`ulimit -l unlimited` or `LimitMEMLOCK=infinity` in the systemd unit.

## Benchmarking protocol

- One change (gate or OS bundle) per comparison, everything else identical.
- Same model, prompt, seed, `--temperature 0`; workers restarted between runs.
- Check `vcgencmd get_throttled` is 0x0 before each run; let the Pis cool
  between runs (fixed cool-down, e.g. 2 minutes).
- n ≥ 5 runs per configuration; compare means against run-to-run stddev.
- Keep the stock build as the permanent baseline; re-run it after any OS
  change.
- Bit-exactness check for gates that claim it: a temperature-0 run must
  produce the identical token stream as the stock build.

`bench.sh` runs one measurement and appends a CSV row:

```
./tools/pi4/bench.sh -l baseline -m model.m -t tokenizer.t \
    -w "10.0.0.2:9998 10.0.0.3:9998 10.0.0.4:9998" -s 128 \
    -p "Continue this story: Once upon a time" -o results.csv
```

## OS tuning

`os-tuning.sh` applies individual, reversible tuning bundles (run as root on
every node, A/B one bundle at a time):

```
sudo ./tools/pi4/os-tuning.sh governor   # performance governor
sudo ./tools/pi4/os-tuning.sh sysctls    # net buffers, busy_poll, swappiness
sudo ./tools/pi4/os-tuning.sh gro-off    # disable GRO on eth0
sudo ./tools/pi4/os-tuning.sh nic        # RX ring / interrupt coalescing (bcmgenet-checked)
sudo ./tools/pi4/os-tuning.sh status     # show current state
```

Nothing persists across reboot (deliberately — persist only measured winners).
Do NOT change the MTU on bcmgenet (hot MTU changes can hang the NIC).

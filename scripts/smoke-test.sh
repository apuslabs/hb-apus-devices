#!/usr/bin/env bash
# Probe the six Apus Network devices on a running HyperBEAM node.
#
# Usage: scripts/smoke-test.sh [PROBE ...]
#
# Probes (default: all, in this order):
#   meta                   GET  /~meta@1.0/info
#   gpu_inventory          GET  /~gpu_inventory@1.0/digest
#   inference_measurement  GET  /~inference_measurement@1.0/snapshot
#   sev_gpu                GET  /~sev_gpu@1.0/generate with a fresh random nonce
#   inference              GET  /~inference@1.0/health
#   inference_receipt      GET  /~inference_receipt@1.0/health
#   agent                  POST /~agent@1.0/run without tools
#
# Environment:
#   HB_URL   node to probe (default: http://localhost:8734)
#   TIMEOUT  per-request timeout in seconds (default: 60)
#
# Model runtimes, attestation hardware and measurement backends are node
# configuration; the probes send no backend, peer or credential keys. A probe
# for hardware or a backend the node does not have reports FAIL with the
# node's response. Name the probes to run a subset. None of the probes
# creates an Arweave data item.
set -euo pipefail

hb_url=${HB_URL:-http://localhost:8734}
hb_url=${hb_url%/}
timeout=${TIMEOUT:-60}
all_probes=(meta gpu_inventory inference_measurement sev_gpu inference inference_receipt agent)

if [ -t 1 ]; then
    pass=$'\033[32mPASS\033[0m'
    fail=$'\033[31mFAIL\033[0m'
else
    pass=PASS
    fail=FAIL
fi

failures=0
body_file=$(mktemp)
trap 'rm -f "$body_file" "$body_file.err"' EXIT

# probe NAME EXPECT METHOD PATH [JSON_BODY]
# Passes when the node answers 200 and, if EXPECT is not empty, the response
# contains EXPECT.
probe() {
    local name=$1 expect=$2 method=$3 path=$4 data=${5:-}
    local args=(-sS -o "$body_file" -w '%{http_code} %{time_total}'
        --max-time "$timeout" -X "$method"
        -H 'accept: application/json' -H 'accept-bundle: true')
    if [ -n "$data" ]; then
        args+=(-H 'content-type: application/json' --data "$data")
    fi
    local result status=000 seconds=0 detail
    : > "$body_file"
    if result=$(curl "${args[@]}" "$hb_url$path" 2> "$body_file.err"); then
        status=${result%% *}
        seconds=${result##* }
        detail=$(head -c 300 "$body_file" | tr '\n' ' ')
    else
        detail=$(tr '\n' ' ' < "$body_file.err")
    fi
    if [ "$status" != "200" ]; then
        failures=$((failures + 1))
        printf '%s  %-22s HTTP %s  %s\n' "$fail" "$name" "$status" "$detail"
    elif [ -n "$expect" ] && ! grep -qF -- "$expect" "$body_file"; then
        failures=$((failures + 1))
        printf '%s  %-22s HTTP %s  response lacks %s: %s\n' \
            "$fail" "$name" "$status" "$expect" "$detail"
    else
        printf '%s  %-22s HTTP %s  %ss\n' "$pass" "$name" "$status" "$seconds"
    fi
}

run() {
    local nonce
    case "$1" in
        meta)
            probe meta "" GET "/~meta@1.0/info" ;;
        gpu_inventory)
            probe gpu_inventory inventory-digest GET "/~gpu_inventory@1.0/digest" ;;
        inference_measurement)
            probe inference_measurement supported GET \
                "/~inference_measurement@1.0/snapshot" ;;
        sev_gpu)
            # The evidence must echo the nonce chosen here.
            nonce=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
            probe sev_gpu "$nonce" GET "/~sev_gpu@1.0/generate?nonce=$nonce" ;;
        inference)
            probe inference "" GET "/~inference@1.0/health" ;;
        inference_receipt)
            probe inference_receipt "" GET "/~inference_receipt@1.0/health" ;;
        agent)
            probe agent agent-answer POST "/~agent@1.0/run" \
                '{"agent-user-prompt":"Reply with the single word: pong","agent-disable-tools":true}' ;;
        *)
            echo "error: unknown probe '$1' (probes: ${all_probes[*]})" >&2
            exit 2 ;;
    esac
}

echo "Probing $hb_url"
if [ "$#" -eq 0 ]; then
    set -- "${all_probes[@]}"
fi
for name in "$@"; do
    run "$name"
done

if [ "$failures" -gt 0 ]; then
    echo "$failures of $# probes failed"
    exit 1
fi
echo "all $# probes passed"

#!/usr/bin/env bash
set -euo pipefail

HB_URL="${HB_URL:-http://127.0.0.1:8734}"
AI_PEER="${AI_PEER:-http://localhost:8080}"
AI_PATH="${AI_PATH:-/v1/chat/completions}"
MODEL="${MODEL:-google/gemma-4-26B-A4B-it}"

if [ -t 1 ] || [ "${FORCE_COLOR:-0}" = "1" ]; then
  BOLD=$'\033[1m'
  CYAN=$'\033[36m'
  YELLOW=$'\033[33m'
  RESET=$'\033[0m'
else
  BOLD=""
  CYAN=""
  YELLOW=""
  RESET=""
fi

section() {
  printf '\n%s%s== %s ==%s\n' "$BOLD" "$CYAN" "$1" "$RESET"
}

cmd() {
  printf '%s$ %s%s\n' "$YELLOW" "$*" "$RESET"
}

section "Apus HyperBEAM Preload Device Validation"
echo "repo: https://github.com/apuslabs/hb-apus-devices"
echo "pin:  2c03978a3d201444bf7aada3eb35809153e41ef3"

section "1. Device Forge Roots"
cmd "grep -H '^-implements' src/dev_agent.erl src/dev_inference.erl src/dev_sev_gpu.erl"
grep -H '^-implements' src/dev_agent.erl src/dev_inference.erl src/dev_sev_gpu.erl \
  src/dev_gpu_inventory.erl src/dev_apus_measurement.erl \
  src/dev_inference_receipt.erl

section "2. Device Forge Package Artifacts"
cmd "ls -lh _build/device-packages/*.beam-archive.zip"
ls -lh _build/device-packages/*.beam-archive.zip
echo
for archive in _build/device-packages/*.beam-archive.zip; do
  echo "-- $(basename "$archive")"
  cmd "unzip -l $archive | grep 'ebin/.*\\.beam'"
  unzip -l "$archive" | grep 'ebin/.*\.beam'
done

section "3. Published Arweave IDs"
cmd "grep -E '^- (agent|inference|sev_gpu)@1.0 spec=' PUBLISH.md"
grep -E '^- (agent|inference|sev_gpu|gpu_inventory|apus_measurement|inference_receipt)@1.0 spec=' PUBLISH.md

section "4. Local Forge Preloaded Store"
cmd "ls -lh _build/device-local-store/data.mdb"
ls -lh _build/device-local-store/data.mdb
cmd "curl -fsS -i \"$HB_URL/~meta@1.0/info\" | grep -Ei '^(status|preloaded-devices-index|preloaded-store\\+link):'"
curl -fsS -i "$HB_URL/~meta@1.0/info" \
  | grep -Ei '^(status|preloaded-devices-index|preloaded-store\+link):'

section "5. Device Calls Resolved By Local HyperBEAM"
echo "-- calling http://127.0.0.1:8734/~inference@1.0/health"
cmd "curl -fsS \"$HB_URL/~inference@1.0/health\""
curl -fsS "$HB_URL/~inference@1.0/health"
echo

echo "-- calling http://127.0.0.1:8734/~sev_gpu@1.0/verify"
cmd "curl -fsS -i \"$HB_URL/~sev_gpu@1.0/verify\" | grep -Ei '^(status|ao-result):|^nif_not_loaded$|^true$|^false$'"
curl -fsS -i "$HB_URL/~sev_gpu@1.0/verify" \
  | grep -Ei '^(status|ao-result):|^nif_not_loaded$|^true$|^false$'
echo

echo "-- calling http://127.0.0.1:8734/~agent@1.0/run"
echo "model endpoint: $AI_PEER$AI_PATH"
echo "model: $MODEL"
cmd "curl -fsS -i \"$HB_URL/~agent@1.0/run\" -H 'content-type: application/json' -d '{...}' | grep -E 'status:|device:|agent-model:|agent-iterations:|agent-answer:'"
curl -fsS -i "$HB_URL/~agent@1.0/run" \
  -H 'content-type: application/json' \
  -d "{
    \"agent-user-prompt\": \"Reply in one short English sentence: What is the capital of France?\",
    \"agent-api-peer\": \"$AI_PEER\",
    \"agent-api-path\": \"$AI_PATH\",
    \"agent-model\": \"$MODEL\",
    \"agent-disable-tools\": true,
    \"agent-max-iterations\": 1
  }" \
  | awk 'BEGIN{IGNORECASE=1} /^status:|^device:|^agent-model:|^agent-iterations:|^agent-answer:/ {print}'

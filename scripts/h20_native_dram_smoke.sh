#!/bin/bash
# Functional smokes only. Does not unmount nvme6 or start GDS/uGDS.
set -euo pipefail
IMAGE=${IMAGE:-vllm-lmcache-ugds:0.30.0-0.5.5-cu129}
MODEL=/mnt/nvme0n1/luyi/agentic-ai-serving/tmp-q235/models/Qwen3-Coder-30B-A3B-Instruct-FP8
ROOT=/home/jinkim/ugds-lmcache-feasibility/runs
STAMP=$(date +%Y%m%d-%H%M%S)
RUN=$ROOT/${STAMP}-native-dram-smoke
mkdir -p "$RUN"
exec > >(tee -a "$RUN/smoke.log") 2>&1
echo "START $(date -Is) IMAGE=$IMAGE"
echo "RUN $RUN"
printf '%s\n' '{"status":"running","phase":"initialize"}' > "$RUN/status.json"

write_status() {
    local status=$1
    local phase=$2
    local reason=${3:-}
    python3 - "$RUN/status.json" "$status" "$phase" "$reason" <<'PY'
import json
import sys

path, status, phase, reason = sys.argv[1:]
data = {"status": status, "phase": phase}
if reason:
    data["reason"] = reason
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

cleanup() {
    set +e
    for name in h20-native-smoke h20-dram-vllm; do
        sudo docker logs "$name" > "$RUN/$name.final.log" 2>&1 || true
    done
    sudo docker rm -f h20-native-smoke h20-dram-lmcache h20-dram-vllm >/dev/null 2>&1 || true
}
on_exit() {
    local rc=$?
    cleanup
    if [ "$rc" -ne 0 ]; then
        write_status failed "${PHASE:-unknown}" "exit_code=$rc"
        echo "SMOKE_FAIL rc=$rc phase=${PHASE:-unknown} run=$RUN"
    fi
    exit "$rc"
}
trap on_exit EXIT

wait_models() {
    local i
    for i in $(seq 1 180); do
        if curl -sf http://127.0.0.1:8000/v1/models >/dev/null; then
            return 0
        fi
        if ! sudo docker ps --format '{{.Names}}' | grep -q "$1"; then
            echo "CONTAINER_EXIT $1"
            sudo docker logs "$1" > "$RUN/$1.early-exit.log" 2>&1 || true
            return 1
        fi
        sleep 10
    done
    echo "TIMEOUT $1"
    return 1
}

complete() {
    local out=$1
    curl -sS -m 120 http://127.0.0.1:8000/v1/completions \
        -H 'Content-Type: application/json' \
        -d '{"model":"qwen3-coder","prompt":"'"$(python3 -c 'print(("The quick brown fox jumps over the lazy dog. "*80).replace("\"","\\\""))')"'","max_tokens":8,"temperature":0}' \
        > "$out"
}

validate_text_match() {
    local label=$1
    local first=$2
    local second=$3
    python3 - "$label" "$first" "$second" <<'PY'
import json
import sys

label, first_path, second_path = sys.argv[1:]
first = json.load(open(first_path))
second = json.load(open(second_path))
first_choice = first["choices"][0]
second_choice = second["choices"][0]
first_text = first_choice["text"]
second_text = second_choice["text"]
print(f"{label}_FIRST", repr(first_text))
print(f"{label}_SECOND", repr(second_text))
if not first_choice.get("finish_reason"):
    raise SystemExit(f"{label}: first completion has no finish_reason")
if not second_choice.get("finish_reason"):
    raise SystemExit(f"{label}: second completion has no finish_reason")
if first_text != second_text:
    raise SystemExit(f"{label}: completion text mismatch")
print(f"{label}_TEXT_MATCH")
PY
}

validate_dram_l1() {
    python3 - "$RUN" <<'PY'
import json
import re
import sys
from pathlib import Path

run = Path(sys.argv[1])

def completion_text(path: str) -> str:
    data = json.load(open(run / path))
    choice = data["choices"][0]
    if not choice.get("finish_reason"):
        raise SystemExit(f"{path}: missing finish_reason")
    return choice["text"]

def read_metric_samples(path: Path) -> dict[str, float]:
    samples: dict[str, float] = {}
    if not path.exists():
        return samples
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0].split("{", 1)[0]
        try:
            value = float(parts[1])
        except ValueError:
            continue
        samples[name] = samples.get(name, 0.0) + value
    return samples

def metric_delta(before: dict[str, float], after: dict[str, float], pattern: str) -> float:
    regex = re.compile(pattern, re.IGNORECASE)
    names = set(before) | set(after)
    return sum(after.get(name, 0.0) - before.get(name, 0.0) for name in names if regex.search(name))

before = read_metric_samples(run / "dram-metrics-before.txt")
after_cold = read_metric_samples(run / "dram-metrics-after-cold.txt")
after_warm = read_metric_samples(run / "dram-metrics-after-warm.txt")
log_text = (run / "dram-vllm.log").read_text(errors="replace") if (run / "dram-vllm.log").exists() else ""

cold_text = completion_text("dram-cold.json")
warm_text = completion_text("dram-warm.json")
print("DRAM_COLD", repr(cold_text))
print("DRAM_WARM", repr(warm_text))
if cold_text != warm_text:
    raise SystemExit("DRAM: cold/warm text mismatch")

store_delta = metric_delta(
    before,
    after_cold,
    r"lmcache.*(store|stored|write).*(_total|_sum|_count)?$",
)
retrieve_delta = metric_delta(
    after_cold,
    after_warm,
    r"lmcache.*(retrieve|retrieved|load|loaded|read).*(_total|_sum|_count)?$",
)
hit_delta = metric_delta(
    after_cold,
    after_warm,
    r"lmcache.*(hit).*token|external.*hit.*token|lookup.*hit.*token",
)
chunk_load_delta = metric_delta(
    after_cold,
    after_warm,
    r"lmcache.*(chunk).*load|lmcache.*load.*chunk|lmcache.*l1_read.*chunk",
)
local_apc_delta = metric_delta(
    before,
    after_warm,
    r"vllm.*prefix.*cache.*hit.*token|vllm.*prefix.*hit",
)

stored_tokens = sum(int(x) for x in re.findall(r"Stored\s+(\d+)\s+tokens", log_text))
retrieved_tokens = sum(int(x) for x in re.findall(r"Retrieved\s+(\d+)\s+tokens", log_text))
log_hit_tokens = sum(int(x) for x in re.findall(r"(?:hit|matched)\s+(\d+)\s+tokens", log_text, re.IGNORECASE))
log_loaded_chunks = sum(int(x) for x in re.findall(r"loaded\s+(\d+)\s+chunks", log_text, re.IGNORECASE))

print("DRAM_METRIC_STORE_DELTA", store_delta)
print("DRAM_METRIC_RETRIEVE_DELTA", retrieve_delta)
print("DRAM_METRIC_HIT_TOKEN_DELTA", hit_delta)
print("DRAM_METRIC_CHUNK_LOAD_DELTA", chunk_load_delta)
print("DRAM_METRIC_LOCAL_APC_DELTA", local_apc_delta)
print("DRAM_LOG_STORED_TOKENS", stored_tokens)
print("DRAM_LOG_RETRIEVED_TOKENS", retrieved_tokens)
print("DRAM_LOG_HIT_TOKENS", log_hit_tokens)
print("DRAM_LOG_LOADED_CHUNKS", log_loaded_chunks)

has_store = store_delta > 0 or stored_tokens > 0
has_retrieve = retrieve_delta > 0 or retrieved_tokens > 0 or chunk_load_delta > 0 or log_loaded_chunks > 0
has_hit = hit_delta > 0 or log_hit_tokens > 0
if not has_store:
    raise SystemExit("DRAM: no cold store evidence")
if not has_retrieve:
    raise SystemExit("DRAM: no warm retrieve/load evidence")
if not has_hit:
    raise SystemExit("DRAM: no warm external hit-token evidence")
if local_apc_delta != 0:
    raise SystemExit(f"DRAM: local APC hit delta is nonzero: {local_apc_delta}")
print("DRAM_L1_VALIDATED")
PY
}

if [ "${SKIP_NATIVE:-0}" != "1" ]; then
echo "=== NATIVE ==="
PHASE=native
sudo docker run -d --name h20-native-smoke \
    --gpus '"device=2"' --network host --ipc host --shm-size 16g \
    -v "$MODEL:/model:ro" \
    -e VLLM_SERVER_DEV_MODE=1 \
    --entrypoint vllm \
    "$IMAGE" \
    serve /model \
    --served-model-name qwen3-coder \
    --max-model-len 4096 \
    --gpu-memory-utilization 0.80 \
    --no-enable-prefix-caching \
    --enforce-eager \
    --host 127.0.0.1 --port 8000
if ! wait_models h20-native-smoke; then
    echo "NATIVE_FAIL $(date -Is)"
    exit 1
fi
complete "$RUN/native-completion-1.json"
complete "$RUN/native-completion-2.json"
validate_text_match NATIVE "$RUN/native-completion-1.json" "$RUN/native-completion-2.json"
sudo docker logs h20-native-smoke > "$RUN/native-vllm.log" 2>&1 || true
sudo docker rm -f h20-native-smoke
echo "NATIVE_OK $(date -Is)"
fi

echo "=== DRAM ==="
PHASE=dram
KV='{"kv_connector":"LMCacheMPConnector","kv_connector_module_path":"lmcache.integration.vllm.lmcache_mp_connector","kv_role":"kv_both"}'
sudo docker run -d --name h20-dram-vllm \
    --gpus '"device=2"' --network host --ipc host --shm-size 16g \
    -v "$MODEL:/model:ro" \
    -e VLLM_SERVER_DEV_MODE=1 \
    -e KV_TRANSFER_CONFIG="$KV" \
    --entrypoint bash \
    "$IMAGE" -lc '
set -e
lmcache server \
  --host 127.0.0.1 --port 5555 \
  --http-host 127.0.0.1 --http-port 8080 \
  --l1-size-gb 8 --eviction-policy LRU --chunk-size 256 \
  --enable-extra-logging --extra-logging-interval 5 &
python3 - << "PY"
import time, urllib.request
for _ in range(30):
    try:
        urllib.request.urlopen("http://127.0.0.1:8080/metrics", timeout=2)
        break
    except Exception:
        time.sleep(2)
else:
    raise SystemExit("lmcache metrics did not come up")
PY
exec vllm serve /model \
  --served-model-name qwen3-coder \
  --max-model-len 4096 \
  --gpu-memory-utilization 0.80 \
  --no-enable-prefix-caching \
  --enforce-eager \
  --host 127.0.0.1 --port 8000 \
  --kv-transfer-config "$KV_TRANSFER_CONFIG"
'
if ! wait_models h20-dram-vllm; then
    echo "DRAM_VLLM_FAIL $(date -Is)"
    exit 1
fi
curl -sf http://127.0.0.1:8080/metrics > "$RUN/dram-metrics-before.txt"
complete "$RUN/dram-cold.json"
sleep 5
curl -sf http://127.0.0.1:8080/metrics > "$RUN/dram-metrics-after-cold.txt"
curl -sf -X POST http://127.0.0.1:8000/reset_prefix_cache > "$RUN/reset-prefix.txt"
complete "$RUN/dram-warm.json"
sleep 5
curl -sf http://127.0.0.1:8080/metrics > "$RUN/dram-metrics-after-warm.txt"
sudo docker logs h20-dram-vllm > "$RUN/dram-vllm.log" 2>&1 || true
validate_dram_l1
echo "DRAM_OK $(date -Is)"
echo "SMOKE_OK $RUN"
write_status passed complete ""

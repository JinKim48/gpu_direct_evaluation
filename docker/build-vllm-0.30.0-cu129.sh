#!/bin/bash
# Server-side tmux entrypoint. Survives SSH logout.
set -uo pipefail
ROOT=/home/jinkim/ugds-lmcache-feasibility
LOG=$ROOT/build/vllm-cu129-build.log
cd "$ROOT"
exec > >(tee -a "$LOG") 2>&1
echo "START $(date -Is)"
sudo -E docker build \
    --network=host \
    -f build/Dockerfile.vllm-0.30.0-cu129 \
    -t vllm-lmcache-ugds:0.30.0-0.5.5-cu129 \
    .
ec=$?
echo "BUILD_EXIT:${ec} $(date -Is)"
if [ "$ec" -ne 0 ]; then
    echo "SESSION_HOLD $(date -Is)"
    sleep infinity
fi
echo "SMOKE_START $(date -Is)"
gpu_line=$(nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader | sed -n '3p')
echo "GPU2 ${gpu_line}"
apps=$(nvidia-smi -i 2 --query-compute-apps=pid,process_name --format=csv,noheader)
if [ -n "$apps" ]; then
    echo "SMOKE_SKIP GPU2 busy"
    echo "SMOKE_EXIT:2 $(date -Is)"
    echo "SESSION_HOLD $(date -Is)"
    sleep infinity
fi
sudo docker run --rm --gpus '"device=2"' --entrypoint python3 \
    vllm-lmcache-ugds:0.30.0-0.5.5-cu129 \
    -c 'import torch, vllm, lmcache; print(torch.__version__); print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0)); print(vllm.__version__); print(lmcache.__version__)'
sec=$?
echo "SMOKE_EXIT:${sec} $(date -Is)"
echo "SESSION_HOLD $(date -Is)"
sleep infinity

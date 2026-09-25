#!/bin/bash
# One-click H20 runner. smoke/gds never touch the nvme6 filesystem type.
# ugds refuses to continue without the explicit destructive acknowledgement.
# --dry-run stops after preflight.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
PROFILE=$ROOT/config/h20-gpu2-nvme6.env
MODE=${1:-}
DRY=0
ACK=""
if [ "${2:-}" = "--dry-run" ]; then
    DRY=1
fi
if [ "${2:-}" = "--ack-destroy-nvme6" ]; then
    ACK=${3:-}
fi
if [ "${3:-}" = "--dry-run" ]; then
    DRY=1
fi

fail() {
    echo "FAIL phase=$PHASE $*"
    if [ -n "${RUN_DIR:-}" ]; then
        printf '%s\n' "{\"status\":\"failed\",\"phase\":\"$PHASE\",\"reason\":\"$*\"}" > "$RUN_DIR/status.json"
    fi
    exit 1
}

PHASE=initialize
case "$MODE" in
    smoke|gds|ugds) ;;
    *)
        echo "usage: $0 <smoke|gds|ugds> [--dry-run] [--ack-destroy-nvme6 SERIAL]"
        exit 2
        ;;
esac

if [ "$MODE" = "ugds" ] && [ "$ACK" != "BTAX414103403P8CGN" ]; then
    echo "FAIL phase=initialize ugds requires --ack-destroy-nvme6 BTAX414103403P8CGN"
    exit 1
fi

# shellcheck disable=SC1090
source "$PROFILE"
RUN_ID=$(date +%Y%m%d-%H%M%S)-$MODE
if [ "$DRY" -eq 1 ]; then
    RUN_ID=${RUN_ID}-dry-run
fi
RUN_DIR=$RUN_ROOT/$RUN_ID
mkdir -p "$RUN_DIR"
printf '%s\n' "{\"status\":\"running\",\"phase\":\"initialize\",\"mode\":\"$MODE\",\"dry_run\":$DRY}" > "$RUN_DIR/status.json"
cp "$PROFILE" "$RUN_DIR/profile.env"
{
    echo "run_id=$RUN_ID"
    echo "mode=$MODE"
    echo "dry_run=$DRY"
    echo "image=$IMAGE"
    echo "model=$MODEL_DIR"
    echo "gpu=$GPU_INDEX $GPU_UUID $GPU_BDF"
    echo "nvme=$NVME_DEV $NVME_BDF $NVME_SERIAL"
    echo "mount=$GDS_MOUNT"
    date -Is
} > "$RUN_DIR/manifest.txt"
echo "RUN_DIR $RUN_DIR"

PHASE=preflight
driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
[ "$driver" = "$EXPECTED_DRIVER" ] || fail "driver $driver != $EXPECTED_DRIVER"
gpu_row=$(nvidia-smi --query-gpu=index,uuid,pci.bus_id --format=csv,noheader | sed -n "$((GPU_INDEX + 1))p")
echo "$gpu_row" | grep -q "$GPU_UUID" || fail "GPU row $gpu_row"
apps=$(nvidia-smi -i "$GPU_INDEX" --query-compute-apps=pid,process_name --format=csv,noheader)
[ -z "$apps" ] || fail "GPU$GPU_INDEX busy: $apps"
serial=$(sudo nvme id-ctrl "$NVME_DEV" | awk -F: '/^sn / {gsub(/ /,"",$2); print $2}')
[ "$serial" = "$NVME_SERIAL" ] || fail "serial $serial"
nvme_name=$(basename "$NVME_DEV" | sed 's/n[0-9]*$//')
bdf=$(basename "$(readlink -f /sys/class/nvme/$nvme_name/device)")
[ "$bdf" = "$NVME_BDF" ] || fail "bdf $bdf"
opts=$(findmnt -no OPTIONS "$GDS_MOUNT")
echo "$opts" | grep -q "data=ordered" || fail "mount options $opts"
src=$(findmnt -no SOURCE "$GDS_MOUNT")
[ "$src" = "$NVME_DEV" ] || fail "mount source $src"
[ -r "$MODEL_DIR/config.json" ] || fail "model config unreadable"
for dev in $NVIDIA_FS_DEVICES; do
    [ -e "$dev" ] || fail "missing $dev"
done
if ! sudo docker image inspect "$IMAGE" >/dev/null 2>&1; then
    fail "image $IMAGE is not present"
fi
image_id=$(sudo docker image inspect --format '{{.Id}}' "$IMAGE")
echo "image_id=$image_id" >> "$RUN_DIR/manifest.txt"
ss -ltn | awk '{print $4}' | grep -Eq ":${VLLM_PORT}$|:${LMCACHE_METRICS_PORT}$" && fail "port $VLLM_PORT or $LMCACHE_METRICS_PORT is in use"
echo "PREFLIGHT_OK driver=$driver image=$image_id mount=$opts"
printf '%s\n' "{\"status\":\"preflight_ok\",\"phase\":\"preflight\",\"mode\":\"$MODE\",\"dry_run\":$DRY,\"image\":\"$image_id\"}" > "$RUN_DIR/status.json"

if [ "$DRY" -eq 1 ]; then
    echo "DRY_RUN_OK $RUN_DIR"
    exit 0
fi

echo "FAIL phase=prepare runtime phases are not enabled until the image smoke passes"
exit 3

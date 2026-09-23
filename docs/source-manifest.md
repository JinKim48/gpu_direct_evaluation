# vLLM LMCache uGDS Source Manifest

Created: 2026-09-24

This manifest records the source-of-truth repositories for the H20 GDS/uGDS feasibility work. Local source under `/Users/bytedance/repo/xPU_drv` is canonical; remote servers are build/run targets.

## Repositories

| Component | Local path | Origin fork | Upstream | Branch | Pinned version | SHA |
|---|---|---|---|---|---|---|
| LMCache | `/Users/bytedance/repo/xPU_drv/LMCache` | `https://github.com/JinKim48/LMCache.git` | `https://github.com/LMCache/LMCache.git` | `exp/lmcache-ugds-h20-v0.5.5` | `v0.5.5` | `05a013b29da78cf2321b9b46ec5039dde2fb0bb0` |
| uGDS | `/Users/bytedance/repo/xPU_drv/uGDS` | `https://github.com/JinKim48/uGDS.git` | `https://github.com/ScaleX-IO/uGDS.git` | `exp/lmcache-ugds-h20` | latest fork `main` at setup time | `515d606992dd61c362e90bd887f5bdbb98992096` |
| vLLM | `/Users/bytedance/repo/xPU_drv/vllm` | `https://github.com/JinKim48/vllm.git` | `https://github.com/vllm-project/vllm.git` | `exp/lmcache-ugds-h20-v0.30.0` | `v0.30.0` | `ced6857afa0ea7b2e3f0846a62e1394e90f15607` |
| Evaluation | `/Users/bytedance/repo/xPU_drv/gpu_direct_evaluation` | `https://github.com/JinKim48/gpu_direct_evaluation.git` | none | `main` | initial workspace | `eb11e8088ad922cc8b9ba71dab532a004d51d2f6` |

## Docker Image Checks

Checked with `docker manifest inspect`.

| Image | Result | Notes |
|---|---|---|
| `vllm/vllm-openai:v0.30.0` | found | manifest list includes `linux/amd64` and `linux/arm64` |
| `vllm/vllm-openai:latest` | found | manifest list includes `linux/amd64` and `linux/arm64` |
| `lmcache/vllm-openai:v0.5.5` | found | Docker Hub manifest exists |
| `lmcache/lmcache:v0.5.5` | not found or private | registry returned denied/unauthorized |
| `lmcache/lmcache:latest` | not found or private | registry returned denied/unauthorized |
| `ghcr.io/lmcache/lmcache:v0.5.5` | not found or private | registry returned denied |
| `ghcr.io/lmcache/lmcache:latest` | not found or private | registry returned denied |

## Operating Rules

- Commit reusable scripts, setup docs, manifests, and small utilities to `gpu_direct_evaluation`.
- Do not commit large benchmark outputs, model files, build directories, or raw run logs.
- Keep component patches in the component fork branches, not in the evaluation repo.
- Record every server run with exact source SHAs, Docker image digests or tags, GPU/SSD topology, mount options, and GDS mode evidence.

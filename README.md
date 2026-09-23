# GPU Direct Evaluation

Utilities, scripts, setup notes, and run artifacts metadata for evaluating vLLM, LMCache, NVIDIA GDS, and uGDS on GPU Direct Storage capable servers.

## Scope

- Keep reusable test scripts and setup guides in this repository.
- Keep large benchmark outputs, model files, build artifacts, and raw logs outside Git.
- Record exact source SHAs, Docker images, server configuration, and storage/GPU topology for each run.

## Current Experiment

- Target server: `dpu2jinkim`
- Main plan document: `/Users/bytedance/repo/xPU_drv/md/vllm-lmcache-ugds-feasibility-plan.md`
- Baseline repos: `LMCache`, `uGDS`, and `vllm` cloned under the same local workspace.

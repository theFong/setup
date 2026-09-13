# DeepSeek V4.1 vLLM runtime

The runtime is built from vLLM merge commit
`e77daef89e18e08321ae7b8b24827eedd5fe8673`, selected by the fail-closed PR
gate for [vLLM #56214](https://github.com/vllm-project/vllm/pull/56214).

The default upstream Dockerfile build image is amd64-only. The selected commit's
own arm64 CI and release lanes use
`pytorch/manylinuxaarch64-builder:cuda13.0-b8b5f17a7d9ccfc25bbc5cf17b3fcea12964a042`
and compile architecture families `9.0 10.0 11.0 12.0`, explicitly including
DGX Spark/GB10 and the Grace/Blackwell targets. This package follows that lane,
with the arm64 platform manifests pinned directly:

- build base:
  `sha256:994bed2b225a9ff0f6fbe85c85fe84fbeac9031bb909442e18178484798529df`
- final CUDA base:
  `sha256:56d9d8183e2181a20be6b0d3801d1f056a0e75c17706df939ba207b126e1cb9c`

`Dockerfile` is deliberately an identity wrapper: it adds provenance labels but
has no `RUN`, `COPY`, or `ADD` instruction. All software comes from the selected
commit's upstream `docker/Dockerfile` and its `vllm-openai` target.

Run from the setup repository after the pin gate has populated the manifest:

```bash
webster/deepseek-v41/scripts/build-runtime.sh \
  --run-root /home/ubuntu/deepseek-v41-runs/CHANGE_ID
```

The script freezes a bundle, binary diff, submodule state, deterministic source
archive, registry evidence, and dependency freeze. It builds once on Shamu under
a four-CPU, 96-GiB, low-I/O cgroup; no GPU device is granted to BuildKit. It then
saves, checksums, copies over the `10.10.1.2` rail with `rsync --checksum
--bwlimit=250000`, loads on Tilikum, and requires identical image IDs and commit
labels. GLM health is probed directly over NetBird from the orchestrator, so an
unrelated SSH transport stall cannot block or misclassify the serving endpoint;
latency is monitored from Prometheus. Existing divergent
source trees, image tags, archives, or manifest values are never overwritten.

The constrained build first completes upstream's independent
`vllm-runtime-base` target and then builds `vllm-openai`. This preserves the
upstream source and final target while preventing its manylinux and Ubuntu
branches from racing for the same uv distribution-cache lock. At four CPUs, an
arm64 native dependency build can legitimately hold that lock longer than uv's
default 300-second timeout.

The upstream CUDA 13 Dockerfile also applies a 500 MiB wheel-size policy for
artifacts uploaded to PyPI, whose project quota is 800 MiB. The upstream arm64
architecture lane produces a 613.97 MiB wheel at this pinned commit. This
private container build keeps the size check enabled with a recorded 700 MiB
ceiling; it does not discard the check or narrow the upstream architecture set
merely to satisfy the PyPI-oriented default.

The post-build check uses runtime `runc`, `NVIDIA_VISIBLE_DEVICES=void`, and no
network to inspect CLI help and model registry metadata. Because current vLLM
constructs `DeviceConfig` before rendering help, the probe explicitly sets
`VLLM_TARGET_DEVICE=cpu` and requests `--help=engram-config`; the default help
view contains only configuration groups. It requires `DeepseekV41ForCausalLM`,
`--engram-config`, and the baseline
`{"cpu_offload":true,"embedding_across_dp":false}` without loading weights or
compiling a GPU kernel. The model-registry probe discovers the installed vLLM
package with Python rather than globbing multiple possible environment paths;
GNU grep reports exit 2 when any glob is absent even if another path matches.

Optimization PRs `#56220`, `#56227`, and `#56344` are explicitly excluded from
this baseline. Their live PR records and ancestry decisions are captured before
the build; any excluded head found in the selected commit fails the gate.

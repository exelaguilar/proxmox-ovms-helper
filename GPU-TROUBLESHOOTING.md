# Intel GPU findings: `VLM_CB` versus `VLM`

## Summary

This helper uses OVMS's non-continuous-batching `VLM` pipeline for Qwen3-VL-4B on the tested Arrow Lake-P system. The continuous-batching `VLM_CB` pipeline failed on that system with `CL_OUT_OF_RESOURCES`, even when limited to one sequence. Changing only the pipeline to `VLM` and keeping the target set to `GPU` allowed both text and image inference to pass.

This is an evidence-based workaround for one hardware/software combination. It does **not** establish the underlying cause, prove a driver/compiler defect, or guarantee that `VLM_CB` fails on other systems.

## Reproduction context

| Component | Observed setup |
| --- | --- |
| Platform | Proxmox VE host with Intel Arrow Lake-P integrated graphics, PCI ID `8086:7d51`, host driver `i915` |
| Guest | Unprivileged Ubuntu 24.04 LXC; Proxmox host supplies the running kernel and Intel driver |
| Server | Native OVMS binary, version `2026.4.0` |
| Model | `OpenVINO/Qwen3-VL-4B-Instruct-int4-ov`, served as `qwen3-vl-4b` |
| Accelerator | Intel GPU, `--target_device GPU`; no CPU fallback during the successful checks |
| Workload | Text prompt, synthetic-image health check, then a 708×532 doorbell image through the OpenAI-compatible API and Home Assistant LLM Vision |

The doorbell image request took roughly 7 seconds end-to-end in one observed test. This is a single sample, not a benchmark.

## What changed and what passed

The failing service used `--pipeline_type VLM_CB`. The workaround changes that argument to `--pipeline_type VLM`; it leaves the GPU target enabled. With the `VLM` pipeline, the GPU-only health check passed text and image requests, the service remained active without restarts during verification, and Home Assistant's Custom OpenAI provider returned an accurate summary of a separate doorbell frame.

The helper now preserves this behavior on fresh installs and repair runs. Its health check reports failure if GPU inference fails and does not rewrite the target to CPU. This makes a GPU regression visible instead of masking it with CPU execution.

## Tradeoff and remaining risks

- `VLM` does not use continuous batching. OVMS documents continuous batching as the higher-throughput path and recommends trying the corresponding non-CB pipeline when a model/pipeline compatibility problem occurs. For one household camera workflow with occasional requests, the simpler pipeline is a reasonable tradeoff; under concurrent camera traffic, throughput may be lower and requests may queue.
- There was no valid performance comparison against `VLM_CB`, because it failed before completing inference on this system. The approximately 7-second image request is an observation, not proof that `VLM` is equally fast.
- The underlying GPU stack is not necessarily equivalent to bare-metal Ubuntu: the guest has Ubuntu 24.04 userspace, but the Proxmox host provides the kernel and `i915` driver. The fix does not remove that environmental compatibility risk.
- GPU-only operation intentionally has no CPU safety net. If GPU access or inference breaks after a host, driver, or runtime change, inference health checks fail rather than silently switching devices.

OVMS's current troubleshooting guide notes that newly enabled LLM/VLM models may not support continuous batching in all configurations and recommends trying `VLM` when appropriate: [OVMS troubleshooting](https://docs.openvino.ai/2026/model-server/ovms_docs_troubleshooting.html). That guidance makes this a reasonable workaround, but not a root-cause diagnosis.

## Is there a downside to this fix?

For the tested use—one local Home Assistant doorbell/camera analysis at a time—there has been no observed functional downside: the same model accepted text and image requests on the GPU, and LLM Vision worked. The concrete tradeoff is lower concurrency/throughput than continuous batching could provide. If this grows into a multi-camera or high-request-rate service, benchmark the workload and revisit `VLM_CB` after relevant OVMS/driver updates.

The pipeline change does not inherently disable Intel GPU acceleration: successful tests explicitly kept `--target_device GPU`. It also does not prove the graphics compiler or driver is free of other bugs.

## Useful evidence for an upstream report

It is worth documenting this and sharing it with OVMS/Intel support, as long as the report describes the setup and avoids claiming an unproven root cause. The most important caveat is that this is Ubuntu 24.04 guest userspace on a Proxmox host kernel/driver—not a bare-metal Ubuntu test.

Suggested report text:

> On an Intel Arrow Lake-P iGPU (`8086:7d51`, `i915`) passed through to an unprivileged Ubuntu 24.04 LXC on Proxmox, OVMS 2026.4.0 serving `OpenVINO/Qwen3-VL-4B-Instruct-int4-ov` on GPU failed with `CL_OUT_OF_RESOURCES` using `VLM_CB`, including with one sequence. Changing only `--pipeline_type` to `VLM` while retaining `--target_device GPU` passed text and image inference, including a Home Assistant image request. The image request took about 7 seconds in one sample. The LXC uses the Proxmox host kernel and Intel driver, so this is not a bare-metal Ubuntu A/B test. Is this a known pipeline/device limitation, and what additional logs or version details would help isolate it?

Before sending, attach the relevant OVMS startup/crash logs, exact Proxmox host kernel (`uname -r`), host OS/PVE version, GPU firmware/driver and Intel Graphics Compiler/OpenVINO package versions, and the exact service command/config. Redact IPs, tokens, and other private details.

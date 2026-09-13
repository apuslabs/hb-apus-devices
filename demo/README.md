# GPU measurement demo

This is a static, offline-readable demonstration of the v1 Device Forge
composition. It intentionally separates:

- local HyperBEAM observation on a host without NVIDIA;
- a separately recorded RTX 4090 observation from `ssh pc-win`;
- the trust level that would be available when PermawebOS
  `measurement@1.0` consumes the GPU inventory as `hook-body`.

Run it from the repository root:

```sh
python3 -m http.server 8088 --directory demo
```

Open <http://127.0.0.1:8088/>. The page has no external assets or network
dependency. The demo does not claim GPU attestation or inference correctness.

For a live Windows/NVIDIA probe, run the checked-in script through the existing
SSH alias:

~~~sh
ssh pc-win 'powershell -NoProfile -ExecutionPolicy Bypass -Command -' < scripts/pc-win-inference-gpu-probe.ps1
~~~

The probe calls the published inference@1.0 endpoint from the same Windows
host that supplies nvidia-smi data, then emits request, response, and joint
digests. Its provenance remains host-observed; it is not a TPM/GPU
attestation.

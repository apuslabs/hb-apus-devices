# sev_gpu@1.0

`sev_gpu@1.0` provides NVIDIA GPU TEE attestation through a C++ NIF built against NVIDIA's attestation SDK.

## Exports

- `generate`: collect evidence for a nonce.
- `verify`: verify previously collected evidence.

## Native Assets

Run:

```sh
make setup-cc
```

The build writes NIF assets to `priv/dev_sev_gpu/`. Device Forge packages those files into the implementation archive and extracts them at runtime. The device loads the NIF from `hb_device_archive:implementation_dir(?MODULE)`.

On machines without compatible NVIDIA attestation hardware or SDK dependencies, GPU EUnit tests skip cleanly.

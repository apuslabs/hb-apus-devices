# gpu_inventory@1.0

Read-only, host-observed GPU and PCIe inventory.

The device reads PCI display-class devices from sysfs and reports them in a
canonical order. It makes no attestation claim. Volatile runtime values are
kept out of the static digest.

## Keys

| Key | Method | Purpose |
|---|---|---|
| `report` | GET | Full inventory: `devices` with `pci-bdf`, `vendor-id`, `device-id`, `class`, `driver`, `driver-version`, `iommu-group`, `pcie-link`, plus `collected-at-unix`. |
| `digest` | GET | `inventory-digest` over the static fields of `report`, with `provenance-class=host-observed`. |
| `snapshot` | GET | Volatile runtime facts from `nvidia-smi`. |

## Request keys

- `gpu-inventory-root`: sysfs root override, for tests. Read from the request,
  then the base message.

## Responses

Each key returns 200 with the result in `body`. Ask for
`accept: application/json` and `accept-bundle: true` to receive the body
inline instead of as a link.

## Stability

`digest` is stable for an unchanged hardware layout and driver. Use it to
compare nodes or to bind inventory into receipts and measurements.

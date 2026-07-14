# Default kernel readiness is separate from runtime service readiness

**Context:** `capsule compose up` reached `container create` on an arm64 Mac
and failed with:

```text
Error: default kernel not configured for architecture arm64, please use the
`container system kernel set` command to configure it
```

Capsule's existing doctor checks could still report the binary, version, and
API server as ready because none of those checks verifies the runtime's
architecture-specific default kernel selection.

## Apple container 1.1.0 contract

The relevant runtime state can be inspected with:

```sh
container --version
container system status --format json
container system property list --format json
ls -la "$HOME/Library/Application Support/com.apple.container/kernels"
```

Apple's 1.1.0 source is more precise than the property-list output:

- `ClientKernel.getDefaultKernel()` maps the API's not-found response to the
  exact architecture-specific error above.
- `KernelService.getDefaultKernel()` reads the runtime `appRoot`, resolves
  `kernels/default.kernel-<architecture>`, and requires the resolved target to
  exist.
- `container system kernel set --recommended --arch <architecture>` reads the
  recommended kernel URL and an archive member path from runtime properties,
  then installs and selects that kernel.

The `kernel.binaryPath` returned by `system property list` is the path of the
kernel *inside the downloaded archive*. It is not a host path under
`appRoot`, so joining it to `appRoot` is not a valid readiness check.

The default selection is therefore:

```text
<appRoot>/kernels/default.kernel-<architecture>
```

and a broken symlink is equivalent to no configured default. This check proves
selection metadata exists; it does not boot-test the kernel.

Official 1.1.0 sources used to verify the behavior:

- `Sources/Services/ContainerAPIService/Client/ClientKernel.swift`
- `Sources/Services/ContainerAPIService/Server/Kernel/KernelService.swift`
- `Sources/ContainerCommands/System/Kernel/KernelSet.swift`

## Capsule consequence

`ContainerRuntime.defaultKernelReadiness()` now exposes a typed, read-only
result. The CLI client mirrors Apple's managed default-file lookup without
downloading or modifying anything.

`capsule doctor` and the app's diagnostics include a blocking **Default
Kernel** check. When it is missing, the UI can copy—and the CLI prints—the
architecture-specific remediation:

```sh
container system kernel set --recommended --arch arm64
```

`compose up` repeats the readiness check after validating that its prepared
plan is current, but before persisting desired state or creating/pulling any
resource. This converts the late `container create` failure into an immediate,
actionable error with zero Compose mutations.

Capsule never runs the setup command automatically. Kernel installation stays
an explicit user action, consistent with the runtime-install policy.

**Finding:** A running Apple container 1.1.0 API server does not imply that a
default kernel is configured for the host architecture. Readiness must check
the resolved `appRoot/kernels/default.kernel-<arch>` selection separately.

**Consequence:** Diagnostics fail loudly with a copyable setup command, and
Compose refuses `up` before any state or resource mutation when the default
kernel is missing.

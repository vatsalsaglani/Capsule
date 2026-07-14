# A stopped runtime surfaces as an XPC transport failure

**Context:** With Apple container 1.1.0 installed but its system service not
available, the Containers screen rendered the poller's full command error as
the primary UI.

The failing read was the normal structured list command:

```sh
container list --all --format json
```

and the captured 1.1.0 error ended with:

```text
Error: internalError: "failed to list containers" (cause:
"interrupted: \"XPC connection error: Connection invalid\"")
Ensure container system service has been started with `container system start`.
```

For comparison, the same local 1.1.0 installation reports a healthy service
through:

```sh
container --version
container system status
container list --all --format json
```

with `container system status` showing `status running` and the list returning
JSON normally.

**Finding:** On Apple container 1.1.0, a routine list request can expose a raw
`XPC connection error: Connection invalid` when the system service is not
responding. The XPC wording is transport detail, not a useful primary recovery
message, and it does not mean the `container` binary is missing.

**Consequence:** Capsule distinguishes binary absence from service outage. A
missing binary keeps the full-window install/onboarding flow. A polling outage
keeps the shell available, marks runtime status red, offers **Start Runtime**
through `SystemStore`, and retains the original command error only inside a
collapsed **Technical details** disclosure. The poller continues to retry and
turns the status green only after a fresh successful snapshot.

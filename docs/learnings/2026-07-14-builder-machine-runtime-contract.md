# Builder and machine runtime contracts

**Context:** Replacing the Builds and Machines placeholder screens with one
CapsuleKit surface shared by the app and CLI, against Apple `container` 1.1.0
(build `5973b9c`).

**Finding:**

- Empty builder and machine inventories have structured representations:

  ```text
  $ container --version
  container CLI version 1.1.0 (build: release, commit: 5973b9c)
  $ container builder status --format json
  []
  $ container machine list --format json
  []
  ```

  Capsule therefore models a missing builder as `BuilderState.absent` rather
  than treating the empty array as a decode failure. A present builder still
  distinguishes `running` and `stopped`.

- `container machine` 1.1.0 has `create`, `delete`, `inspect`, `list`, `logs`,
  `run`, `set`, `set-default`, and `stop`, but deliberately has no `start`
  subcommand. The `machine run` help contract says it boots the named machine
  if necessary. Capsule's semantic start is therefore the non-interactive
  argv `machine run --root --name <id> true`. This was also pinned with an
  exact argv test; Capsule never invents a nonexistent `machine start` call.

- Machine list JSON uses top-level keys `id`, `status`, `default`,
  `ipAddress`, `cpus`, `memory`, `diskSize`, and `createdDate`. Inspect is a
  one-element JSON array and nests `image.reference` and
  `platform.{os,architecture}` while keeping resource fields top-level.
  Unknown future state strings must remain visible instead of failing the
  entire inventory decode.

- Build progress is durable history, but build tools are free to echo a
  resolved build-argument value. Storing only argument keys in the request
  summary is insufficient; values must also be replaced in every progress
  line before the line reaches Capsule's live UI or history file. This is a
  conservative security boundary, not a claim that every Dockerfile echoes
  its arguments.

- Registering a build includes an `await` to the history actor. If the build
  is not reserved before that suspension, an overlapping builder reset can
  pass an `active.isEmpty` check and race the build. Capsule reserves
  preparing builds before the await and holds a builder-mutation flag across
  lifecycle calls; this is an actor-reentrancy requirement, not only a UI
  button-disable concern.

**Consequence:** `ContainerRuntime`, `RuntimeGateway`, and
`FakeContainerRuntime` expose typed builder and machine operations. The app
and CLI share exact decoding and argv construction; builder lifecycle changes
are serialized against active/preparing builds; build history is bounded and
redacted; machine deletion requires an explicit app confirmation or CLI
`--force`.

Re-run the exact scripted argv/JSON tests and live empty-inventory probes when
the supported runtime moves past 1.x, especially if Apple adds a native
machine-start operation or changes the inspect envelope.

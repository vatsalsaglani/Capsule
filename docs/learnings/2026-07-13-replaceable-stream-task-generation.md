# Replaceable tasks need explicit lifetime ownership

**Context:** The Compose logs UI owns a replaceable `Task` that consumes an
`AsyncThrowingStream`. Pausing, resuming, switching projects, or entering the
Logs tab can cancel one consumer and immediately create another on the main
actor.

**Finding:** `Task.cancel()` is cooperative and does not wait for the cancelled
task's `defer` or `catch` path to finish. Storing only the newest task handle is
therefore insufficient: an older consumer can resume after its replacement,
run `defer { isFollowing = false }`, or publish an error, and overwrite the new
consumer's observable state. Main-actor isolation prevents a data race, but it
does not impose the logical ownership ordering needed by replaceable tasks.

This applies even when both tasks inherit `@MainActor`; actor serialization
still permits reentrancy at every suspension point. The symptom is a live
stream whose UI incorrectly says “Paused”, or an obsolete error appearing
after Retry has already started a healthy replacement.

**Consequence:** `ComposeProjectDetailStore` gives every log consumer a fresh
UUID generation. A consumer may append lines, publish errors, or clear the
following state only while its generation is still current. Starting or
stopping logs invalidates the prior generation before cancellation. The same
pattern should be used for future actor-owned, cancel-and-replace stream tasks;
structured SwiftUI `.task(id:)` consumers remain preferable when the view can
own the entire lifetime directly.

**SwiftUI identity trap:** An unkeyed `.task` belongs to a view identity, not
to every new value passed into that view. `ComposeProjectDetailView` was reused
at the same structural position when the selected project changed. Its first
load task had already completed, so SwiftUI did not run it again for the new
`ComposeProjectDetailStore`; the replacement store remained in `.loading` and
the UI displayed “Resolving project…” indefinitely.

When changing an input should replace the whole screen-local lifecycle, give
the child an explicit `.id(inputID)` at the parent boundary. Also key work that
must follow an input with `.task(id: inputID)`. Here both are intentional: the
identity boundary resets the selected tab and stops the old log consumer via
`onDisappear`, while the keyed task makes the load dependency explicit inside
the detail view.

Verification on 2026-07-13:

```sh
swift test
xcodebuild -quiet -project App/Capsule.xcodeproj -scheme Capsule \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The full CapsuleKit suite passed 292 tests and the generated macOS app target
compiled under Swift 6 strict concurrency.

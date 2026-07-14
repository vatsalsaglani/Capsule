# Foundation `Process` stream exit registration under concurrent tests

**Context:** while verifying the GitHub Actions PTY teardown fix, the complete
Swift package suite intermittently timed out an otherwise instant scripted
`container stats` command. A later stress run stopped making progress after
the child used by `SubprocessLineStream` had already disappeared.

**Finding (macOS 26.1, Xcode 26.3, Swift 6.2.1):** a large parallel burst of
black-box `Foundation.Process` fixtures can expose two independent timing
problems:

1. The 22 scripted CLI tests can collectively delay an instant child long
   enough to trip the production stats deadline. The full suite recorded:

   ```text
   argvEchoStatsUsesNoStreamPollShape():
   timedOut(command: ".../fake-container stats --no-stream --format json web-1 web-2",
            after: 10.0 seconds)
   ```

   The capture file proved the script had received the expected argv, and the
   same test passed alone in 0.477 seconds. This was test-process contention,
   not a `container stats` contract failure.

2. `SubprocessLineStream` drained both pipes and then synchronously called
   `Process.waitUntilExit()`. During the hang, `ps` showed no remaining child,
   while `sample` pinned the test task at:

   ```text
   closure #2 in SubprocessLineStream.run
     -[NSConcreteTask waitUntilExit]
     SubprocessLineStream.swift:156
   ```

   A termination callback may arrive before an async reader is ready to wait.
   Treating exit as a stored result avoids that registration ordering entirely.
   Separately, `AsyncThrowingStream.onTermination` also runs after normal
   `finish()`: signaling the old numeric PID on that path risks targeting a
   newly reused process identity.

Verification after the fix:

```text
$ swift test --filter lineStreamExitCoordinatorHandlesExitBeforeWaiterInstallation
Test run with 1 test in 0 suites passed

$ swift test --filter ScriptedCLITests
Suite ScriptedCLITests passed after 8.584 seconds.
Test run with 22 tests in 1 suite passed
```

**Consequence:** `SubprocessLineStream` installs a lock-guarded termination
coordinator before launch and asynchronously awaits its stored exit code; it
does not call `waitUntilExit()`. Natural stream completion never invokes
process escalation, and delayed SIGKILL is gated by the original coordinator's
exit state before probing the PID. The black-box scripted CLI suite is
serialized so it still exercises real subprocesses without changing Capsule's
production 10-second stats deadline. The rest of the package remains parallel.

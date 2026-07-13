import Darwin

/// Low-level PTY spawn primitive backing `PTYExecSession` (S3 decision,
/// `docs/spikes/S3-pty-exec.md`): TerminalKit owns the PTY directly rather
/// than handing process ownership to SwiftTerm's `LocalProcess`.
enum PTY {
    struct SpawnError: Error, Sendable {
        let message: String
    }

    /// Forks a child that `execv`s `executablePath` with `arguments` under a
    /// freshly-allocated PTY, sized to `columns`x`rows` from the first
    /// moment (avoids a race where the child reads its initial size before a
    /// separate `resize` call lands).
    ///
    /// Uses Darwin's `forkpty()` (`<util.h>`), which bundles
    /// `posix_openpt`/`grantpt`/`unlockpt`/`fork`/`login_tty` into one call.
    /// `login_tty` is what makes this a *controlling* terminal (session
    /// leader + `TIOCSCTTY` + slave wired to the child's stdio) — that's
    /// required, not incidental: S3's resize proof depends on the kernel
    /// delivering `SIGWINCH` to the foreground process group on
    /// `TIOCSWINSZ`, which only happens with real controlling-terminal
    /// semantics. `posix_spawn` + plain fd-stdio would not provide this.
    ///
    /// **FORK SAFETY — the load-bearing contract of this function.**
    /// `executablePath` and every element of `arguments` are copied into
    /// raw, null-terminated C strings, and the `argv` pointer array itself
    /// is built as **raw allocated memory** (`UnsafeMutablePointer`, not a
    /// Swift `Array`) — all of this happens *before* `forkpty()` is called.
    /// The set of file descriptors to close (see below) is likewise fully
    /// computed and copied into a raw buffer before the fork. Once forked,
    /// the child branch below does **nothing** but close those fds, call
    /// `execv`, and, on failure, `_exit(127)`: no Swift heap allocation, no
    /// ARC retain/release, no `print`, no touching any Swift `Array`/`String`
    /// bridging machinery — only reads of pre-existing raw memory and
    /// `close`/`execv`/`_exit`, all async-signal-safe. This matters because
    /// `fork()` only carries over the calling thread — any lock another
    /// thread held at fork time (`malloc`'s internal locks, Swift runtime
    /// locks used by ARC or String bridging) is frozen mid-acquisition in
    /// the child, and the child's single thread deadlocks the instant it
    /// tries to allocate or retain anything.
    ///
    /// **Why the child closes every fd above 2 before `execv`ing.** Found
    /// via test flakiness, not designed in up front: `forkpty()`/`login_tty`
    /// only reassign fds 0/1/2 to the new PTY slave — any *other* fd already
    /// open in this process (verified live: `swift test`'s own
    /// `swiftpm-testing-helper` process holds dozens of pipe fds above fd 2,
    /// used for concurrent test output capture) is inherited unchanged by
    /// the forked child and, transitively, by anything *it* forks (e.g. a
    /// shell running `sleep 30` as a foreground command). If such an
    /// inherited pipe isn't `O_CLOEXEC`, a long-lived descendant holds it
    /// open long after the fd's true owner has moved on, which can stall
    /// whatever is waiting for that pipe to reach EOF (the exact
    /// "grandchild holds a fd open" hazard already called out in
    /// `SubprocessLineStream.swift`'s doc comment, for the `Pipe`-based
    /// case). Closing every fd above 2 in the child — the standard
    /// subprocess-spawning hygiene practice — severs this regardless of
    /// what the fd's origin or `CLOEXEC` bit is, since it's computed and
    /// closed here, not left for `execv`'s own `CLOEXEC` handling to catch.
    static func spawn(
        executablePath: String,
        arguments: [String],
        columns: Int,
        rows: Int
    ) throws -> (masterFD: Int32, childPID: Int32) {
        guard let pathPointer = strdup(executablePath) else {
            throw SpawnError(message: "strdup failed for executable path")
        }

        var argStrings: [UnsafeMutablePointer<CChar>] = [pathPointer]
        for argument in arguments {
            guard let pointer = strdup(argument) else {
                for allocated in argStrings { free(allocated) }
                throw SpawnError(message: "strdup failed for argument \"\(argument)\"")
            }
            argStrings.append(pointer)
        }

        // Raw C array, allocated (not a Swift `Array`) so the child touches
        // only pre-existing raw memory, never Swift's `Array` machinery,
        // after forking. `+ 1` for the trailing NULL `execv` requires.
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argStrings.count + 1)
        for (index, pointer) in argStrings.enumerated() {
            argv[index] = pointer
        }
        argv[argStrings.count] = nil

        // Snapshot of this process's currently-open fds above stdio (see
        // "Why the child closes every fd above 2" above) — enumerated here,
        // in the parent, before forking; the child only ever reads this
        // pre-built raw buffer.
        let inheritedFDs = openFileDescriptorsAboveStandard()
        let fdsToClose = UnsafeMutablePointer<Int32>.allocate(capacity: max(inheritedFDs.count, 1))
        fdsToClose.initialize(from: inheritedFDs, count: inheritedFDs.count)
        let fdsToCloseCount = inheritedFDs.count

        defer {
            // Only the parent ever reaches this `defer` — the child branch
            // below never returns from this function (it `execv`s or
            // `_exit`s), so it never unwinds through here.
            argv.deallocate()
            for pointer in argStrings { free(pointer) }
            fdsToClose.deallocate()
        }

        var winsz = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &winsz)

        if pid < 0 {
            throw SpawnError(message: "forkpty failed: \(String(cString: strerror(errno)))")
        }

        if pid == 0 {
            // CHILD BRANCH — fork-safety contract above applies from here
            // down. `pathPointer`/`argv`/`fdsToClose` are raw pointers
            // captured before the fork; reading them requires no Swift
            // allocation.
            for index in 0..<fdsToCloseCount {
                close(fdsToClose[index])
            }
            execv(pathPointer, argv)
            _exit(127)
        }

        // PARENT BRANCH.
        return (masterFD, pid)
    }

    /// Enumerates this process's currently-open file descriptors above 2 via
    /// `/dev/fd` (parent-side only, well before any fork — ordinary Swift
    /// code, no fork-safety constraint applies here).
    private static func openFileDescriptorsAboveStandard() -> [Int32] {
        guard let dir = opendir("/dev/fd") else { return [] }
        defer { closedir(dir) }
        var fds: [Int32] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if let fd = Int32(name), fd > 2 {
                fds.append(fd)
            }
        }
        return fds
    }

    /// `TIOCSWINSZ` on the PTY master. No manual `SIGWINCH` send is needed —
    /// the kernel delivers it to the controlling terminal's foreground
    /// process group automatically, and `container exec -it` forwards the
    /// new size into the container-side PTY on its own (S3, verified
    /// empirically, not assumed).
    static func resize(masterFD: Int32, columns: Int, rows: Int) {
        var winsz = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &winsz)
    }
}

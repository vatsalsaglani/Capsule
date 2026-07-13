# Compose pull progress grammar and terminal rendering

**Context:** A five-service `capsule compose up` against Apple `container`
1.1.x produced one stdout line per image-pull tick. Parallel pulls therefore
left hundreds of interleaved lines such as:

```text
[1/2] Fetching image (4 of 17 blobs) [4s]
[1/2] Fetching image 7% (4 of 44 blobs, 65.0/944.7 MB, 4.7 MB/s) [11s]
```

**Finding:** The observed progress grammar is anchored by a stage prefix and
elapsed suffix:

```text
[stage/total] phase [percent%] [(comma-separated clauses)] [elapsed-seconds]
```

The optional clauses seen so far are blob counts, transferred/total bytes,
and bytes/second. The runtime sometimes omits the transferred value's unit
(`65.0/944.7 MB`); that value uses the total's unit. Clauses can appear
independently, so the decoder must preserve partial information. Unrecognized
or malformed output is still valid `PullProgress.message`; parsing is
best-effort and never turns a runtime line into a client error.

Interactive terminal rendering is safe only when stdout is a TTY, `TERM` is
not `dumb`, CI is not truthy, `NO_COLOR` is absent/empty, and `CLICOLOR` is not
`0`. Pipes and disabled-color environments must receive bounded, newline-only
plain text: phase transitions, 10% buckets, 10-second indeterminate
heartbeats, unknown output once, and terminal status. Build output remains
uncoalesced because each line is meaningful build-log content.

The live dashboard uses one row per active step and re-queries terminal width
on redraw. It never hides the cursor. Rows are cleared in a `defer` path, and
the renderer permanently falls back to plain output if active rows exceed
terminal height. Runtime text is stripped of ANSI/control characters before
layout or color is applied. Service colors use stable FNV-1a rather than
Swift's randomized `hashValue`, with green and red reserved for terminal
success and failure.

Terminal width is a count of visible cells, not Swift characters or Unicode
scalars. Capsule asks Darwin `wcwidth` for every sanitized scalar, treats
combining marks and variation selectors as zero cells, and uses a conservative
East-Asian/emoji fallback when the process is still in the C locale and
Darwin returns `-1`. Truncation happens across typed row segments before ANSI
is inserted, so a service named `image`, `build`, or `start` cannot cause the
same word in the event kind or phase to be colored accidentally.

Sanitization treats OSC/DCS/SOS/PM/APC as string controls: OSC terminates on
BEL or ST, the others on ST (`ESC \\` or C1 ST), and printable text after the
terminator is retained. C1 control bytes are stripped just like C0 controls.
This matters for registry messages that may contain terminal-title sequences,
not only ordinary SGR color.

Finally, a pull can emit a useful registry diagnostic as an ordinary progress
line and later fail with the generic subprocess text `no stderr output`.
Capsule therefore retains a deduplicated two-line tail of unparsed output and
appends it to the permanent failure line when the final error does not already
contain it. Plain mode may print the first unknown line immediately, but the
tail still preserves the latest context at failure.

**Consequence:** `PullProgress` keeps its raw-message API and exposes an
optional numeric `details` snapshot. `capsule compose` renders icons, stable
service colors, responsive progress bars, byte/rate/elapsed details, and
permanent success/failure lines in capable terminals. Non-TTY stdout stays
greppable, bounded, and free of ANSI, carriage returns, and cursor movement.

Verification on 2026-07-13:

```sh
swift test --filter PullProgress
swift test --filter ComposeProgress
swift build && swift test
xcodegen generate --spec App/project.yml --project App
xcodebuild -project App/Capsule.xcodeproj -scheme Capsule -configuration Release \
  -derivedDataPath dist/DerivedData CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

Parser tests cover the captured phase-only, blob-only, byte/rate, later-stage,
malformed, range, overflow, and unit-inheritance shapes. Renderer tests cover
the capability matrix, five interleaved services, stable colors and ordering,
40/80/120-column layouts, resize/height degradation, bounded plain output,
cleanup, throwing streams, and quiet consumption. The final review run passed 282
tests (the three opt-in live-runtime tests were skipped); the universal Release
app and its embedded universal CLI passed strict ad-hoc signature verification.

The dashboard intentionally uses the single-text-cell symbol vocabulary `◎`,
`▰`, `⇣`, `◆`, `▣`, `▶`, `■`, and `♥` on macOS terminals. It does not use
emoji presentation selectors; service and event text always remains present,
so a terminal with unusual glyph rendering never makes state depend on an
icon alone.

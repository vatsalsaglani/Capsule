# ProjectStore path containment needs two checks

**Context:** While hardening Phase 2 project persistence, project IDs and
service names were being appended directly below `projects/`.

**Finding:** Rejecting `..` and separators and comparing
`standardizedFileURL.pathComponents` prevents lexical traversal, but
standardization does not make an existing symlink safe. A directory such as
`projects/demo -> /tmp/outside` still produces a lexically contained URL while
file writes follow the symlink outside Capsule's root.

This is covered by `projectStoreRejectsTraversalAndSymlinkEscapes`, which
creates that symlink and verifies that a state write is rejected.

Verification on macOS 26 / Swift 6.2:

```text
$ swift test --filter ProjectStoreTests
Test run with 6 tests in 0 suites passed
```

**Consequence:** Every ProjectStore destination is built by one throwing helper.
It validates each dynamic path component, checks the standardized path is below
the standardized projects root, then resolves symlinks and repeats the
containment check before any read, write, or delete.

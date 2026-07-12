# swift-testing: `@Test` function names must be unique across the whole test target, not just per file

**Context:** P1B Batch 3 (Images/System screens) added `ImagesStoreTests.swift`
and `SystemStoreTests.swift` to `AppCoreTests`, each following the established
per-file pattern of a `refresh()`-failure test and a `dismissActionErrorClearsIt`
test (mirroring names already used in `ContainerListStoreTests.swift`/
`ContainerDetailStoreTests.swift` for analogous behavior).

**Finding:** `swift test` failed to *compile* the target with:

```
error: invalid redeclaration of '$s12AppCoreTests33refreshSurfacesAFailureAsThePhase...'
```

pointing at the `@Test` macro expansion, not at any Swift-level symbol
directly visible in either file. The `@Test` macro synthesizes a
`Testing.__TestContentRecordContainer` conformance keyed off the *function
name only* — it does not namespace by file. Two free functions named
`refreshSurfacesAFailureAsThePhase()` (or `dismissActionErrorClearsIt()`) in
two different files of the same test target collide at the generated-symbol
level even though they're `private`-file-scoped in every other respect and
would never collide as plain Swift functions (top-level functions in
different files of the same module *do* collide too, actually — but the
error message here is specifically about the macro-generated registration
type, which is easy to mistake for an unrelated compiler bug on first read).

**Consequence:** every `@Test func` name must be unique across an entire test
target (not just per-file), the same constraint that already applied to
plain top-level function names in one module — this isn't swift-testing
loosening that rule, just a reminder it doesn't either. When mirroring a test
name pattern from another file in the same target (e.g. "one refresh-failure
test per store," "one dismiss-error test per store"), prefix or otherwise
disambiguate the name (`imagesRefreshSurfacesAFailureAsThePhase` /
`systemRefreshSurfacesAFailureAsThePhase`) rather than reusing the exact same
identifier. Cheap to grep for before adding a new test file: `grep -rn "func
<name>("` across `Tests/` first.

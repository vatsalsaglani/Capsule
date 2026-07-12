Project instructions live in AGENTS.md — read it first.

@AGENTS.md

Agent instruction live here - 

## Advisor–Implementor workflow

For non-trivial code changes, use the following sequence:

1. Delegate repository analysis and planning to the `advisor` subagent.
2. Wait for its implementation brief.
3. Critically review the brief against the user's request.
4. Delegate implementation to the `implementor` subagent, including:
   - the original user request;
   - the advisor's complete implementation brief;
   - any corrections or constraints identified by the coordinator.
5. After implementation, review the resulting diff and verification results.
6. For high-risk changes, ask the advisor to perform a final read-only review
   of the implementation.

A change is non-trivial when it affects multiple files, public behaviour,
architecture, persistence, authentication, concurrency, infrastructure,
security, migrations, or requires new tests.

For tiny and unambiguous changes, direct implementation is allowed.

The advisor must never edit implementation files.
The implementor must not begin until it has received the advisor brief.

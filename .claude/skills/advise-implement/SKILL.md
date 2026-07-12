---
name: advise-implement
description: >
  Analyze a non-trivial engineering task with the read-only advisor, implement
  it with the implementor, and perform a final review.
disable-model-invocation: true
argument-hint: "<engineering task>"
---

Execute this task using the Advisor–Implementor workflow:

$ARGUMENTS

Follow this exact sequence:

1. Send the complete task to the `advisor` agent.
2. Wait for a detailed implementation brief.
3. Check that the brief:
   - addresses the full request;
   - references actual repository files;
   - includes risks, tests, and definition of done.
4. Send the original task and full advisor brief to the `implementor` agent.
5. Ask the implementor to make the changes and run verification.
6. Inspect the resulting git diff and test outcomes.
7. Send the completed diff and verification summary back to the `advisor` for
   a final read-only review.
8. If the advisor identifies a concrete defect, send only those actionable
   findings back to the implementor.
9. Return the final implementation summary, verification results, deviations,
   and unresolved concerns.

Do not allow the advisor to edit files.
Do not claim that tests passed unless their commands were actually run.
Do not commit or push unless the user explicitly requests it.

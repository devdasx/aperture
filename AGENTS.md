# Codex Agent Rules

These rules are project-specific and apply to every Codex session in this repository.

1. Do not run Git or GitHub commands. Do not stage, commit, push, pull, branch, inspect Git status or diffs, or call GitHub tools. Make the requested code edits and run only relevant non-Git verification; the user handles version control manually.
2. Start from the exact screen, component, or file named by the user. Do not search the whole repository when the relevant file is known. Expand outward only when the local code does not explain the behavior.
3. For a screenshot-based UI fix with a known component, use no more than two narrowly scoped searches and inspect no more than 200 relevant lines before the first edit, unless those results prove that a dependency must be inspected.
4. Test the simplest local explanation first. Check existing modifiers, semantic tokens, state branches, and component parameters before investigating global architecture or introducing new abstractions.
5. Read only the target file and its direct dependency when required. Do not inspect unrelated screens, services, tests, or project-wide matches for a localized change.
6. Keep command output bounded and useful. Scope `rg` to the smallest relevant path and pattern, request narrow line ranges, and never repeat overlapping searches that return the same context.
7. Keep edits proportional to the request. Do not broaden a one-screen fix to sibling screens or perform unrelated cleanup without explicit evidence that the same defect affects them.
8. Verify with the smallest relevant check. For a small SwiftUI edit, prefer a quiet incremental compile of the affected target; do not run the full test suite, resolve unnecessary packages, install the app, or launch a simulator/device unless the user explicitly requests it or the change cannot otherwise be verified.
9. Stop when the requested behavior is implemented and the focused verification passes. Do not continue exploring hypothetical issues after the acceptance condition is satisfied.
10. If the scope must expand, state the concrete evidence and the next file before reading it. Do not silently turn a localized task into an audit.

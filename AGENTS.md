# Codex Agent Rules

These rules are project-specific and apply to every Codex session in this repository.

1. After making any file edit, commit the completed work and push it directly to `origin/main` before the final response.
2. Before pushing, run `git status --short --branch` and review staged changes so local-only files, secrets, provisioning keys, and unrelated junk are not included.
3. Push only when the requested work is complete and the relevant verification has passed. If verification fails, report the failure and do not push unless the user explicitly asks.
4. After substantial iOS app changes, build a signed Debug app and install it on the paired iPhone named `Thuglife` before the final response.
5. For small text-only or configuration-rule edits, a device install is not required unless the user asks for it.


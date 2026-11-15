---
name: commit-and-push
description: "Use when committing and pushing code changes — local commit + push to a feature branch, following Conventional Commits. Opening the PR is handed off to create-pr."
---

# Commit & Push

Commit and push once a change is done. **Hooks are authoritative** — the repo's git hooks and CI enforce formatting, lint, and tests; this skill runs with them, neither duplicating nor bypassing their work.

## Workflow

### 1. Preflight

```bash
git status
```

Nothing to commit → tell the user and stop.

Done when: the working tree has changes staged or ready to stage.

### 2. Analyze the change

```bash
git diff              # unstaged
git diff --cached     # staged
git log --oneline -5  # align on scope and style
```

Done when: you have settled the type, the scope, and the **why** behind the change (the basis for the message in step 4).

### 3. Stage selectively

- Add files one at a time with `git add <file>` — one commit does one thing; **never** `git add -A` or `git add .`
- **Never** commit secrets or local config (`.env`, `.dev.vars`, key files)
- The pre-commit hook (if any) lints, formats, and re-stages automatically — let it; do not manage this by hand

Done when: what's staged maps to exactly one intent, with no secrets and no stray files.

### 4. Create the commit

Follow **Conventional Commits**: `type(scope): subject`

| Constraint | Rule |
|---|---|
| type | A standard Conventional Commits type (`feat` / `fix` / `refactor` / `chore`, etc.) |
| **scope required** | The affected package/module (e.g. `auth`, `db`, `ci`); if the repo defines an allowlist, choose from it |
| subject | ≤ 100 chars, imperative mood ("add X", not "added X") |
| body | Explains the **why**; optional |
| **no AI signature** | No `Co-Authored-By: Claude/Anthropic`, no "Generated with…", no 🤖 |

Use a HEREDOC to preserve formatting on multi-line messages (if the repo has a guided-commit tool, it lists the valid scopes — prefer those):

```bash
git commit -m "$(cat <<'EOF'
feat(auth): add passkey login

Passwords were the top support-ticket source; passkeys remove
the shared-secret surface entirely.
EOF
)"
```

commit-msg validation fails → fix the message and create a **new** commit.

Done when: the commit lands and validation passes.

### 5. Push

**Never push to main** — use a feature branch + PR.

```bash
git push          # no upstream: git push -u origin <branch>
```

The pre-push hook (if any) runs checks/tests; on failure, fix and re-push. Once it lands, hand off to **create-pr** to open the PR.

Done when: the feature branch is pushed to the remote and the hooks pass.

## Merge / rebase conflicts

A rebase before push, or a pull, may hit conflicts. **Resolve by intent, not by mechanically picking a side**:

1. **See the state clearly**: `git status` plus the conflicted files — know whether you're mid-merge or mid-rebase.
2. **Trace each side's original intent**: read both commit messages, the PR, the source issue/ticket, until you understand **why** each change exists.
3. **Resolve hunk by hunk**: keep both sides when their intents coexist; when they can't, pick the side that fits the goal of this merge/rebase and **note the tradeoff**. **Never invent new behavior. Always finish the resolution — never `--abort`.**
4. **Run the repo's checks** (typecheck → test → format) and fix anything the merge broke.
5. **Close out**: stage and complete the merge/rebase (for a rebase, `--continue` until every commit lands).

Done when: no conflict markers remain, the checks pass, and the merge/rebase is complete.

## Safety rules

- **No** destructive operations: `git reset --hard`, `git checkout .`, `git clean -f`, `--force`
- **No** editing git config, `--no-verify` to skip hooks, or amending an existing commit
- These hold unless the user explicitly asks otherwise. Bypassing hooks locally just moves the failure to CI — don't.

---
name: change_management
description: This skill should be used when Claude detects the user has made changes to repo-tracked files (design / architecture / strategy skills / library code / docs / shipped baselines), or when the user asks "is my PR approved?", "did the owner merge my PR?", "sync my change branch", "check my PR status", "PR my changes for review", or similar. Routes design/code changes through a pull request to the repo owner instead of letting them land directly on main. Two modes — PR mode auto-creates / updates a change branch with an open PR; Sync mode checks PR status and switches the local repo back to main once the owner merges.
version: 0.1.0
---

# change_management

The repo's gatekeeper for design and code changes. The user does the work; this skill handles the branch + PR plumbing so changes get reviewed by the repo owner before landing on `main`.

## When to use this skill

The hook in `.claude/hooks/check_design_change.sh` (set up by `master_configurator` / `settings.json.example`) injects a reminder whenever a tracked file is edited. Claude should then invoke this skill once the round of edits is finished (not after every single edit).

Manual triggers — invoke when the user says any of:
- "is my PR approved?" / "did the owner merge?" / "what's the status of my PR?"
- "sync my change branch" / "switch back to main"
- "PR these changes for review" / "open a PR" / "send my changes for review"

## Two modes

Pick from context. If the user is asking about approval / sync, it's **Sync mode**. Otherwise (they just made changes or asked to PR them) it's **PR mode**.

---

## Mode 1: PR (open or update a PR for current changes)

### Step 1: Determine current branch

```bash
cd "$REPO_ROOT"
current_branch=$(git rev-parse --abbrev-ref HEAD)
```

Three cases:

- **`main`** → Step 2A (create new change branch).
- **`change/*`** → Step 2B (reuse existing branch).
- **Anything else** → Step 2C (ask user; abort if unclear).

### Step 2A: On `main` — create a new change branch

Move uncommitted changes (and any local-only commits ahead of `origin/main`) to a fresh `change/*` branch. Reset `main` to `origin/main` so the operator's `main` stays clean.

```bash
# Generate a descriptive branch name. Pick a slug from what changed
# (e.g., the most-edited skill or doc).
slug="<derive from changed files: e.g. trailing-stop-tweak, docs-refresh, new-strategy-foo>"
date_tag=$(date -u +%Y%m%d)
branch="change/${slug}-${date_tag}"

# Are there local commits ahead of origin/main? If so, move them too.
ahead=$(git rev-list --count origin/main..HEAD)

# Move everything (uncommitted + ahead-commits) to the new branch.
git checkout -b "$branch"

# Reset main to origin/main (preserves the new branch's history).
git branch -f main "origin/main"
```

If `ahead > 0`, the new branch already has those commits. If only uncommitted changes existed, we just need to commit them on the new branch.

### Step 2B: On `change/*` — reuse the branch

Just stay on it. No branch ops needed.

### Step 2C: On some other branch — ask the user

```
You're on branch '<X>'. /change_management expects to operate from
either 'main' (where it'll create a new change branch) or an existing
'change/*' branch (which it'll keep using). What do you want to do?
  - Switch to main first and start fresh
  - Treat '<X>' as a change branch (rename to 'change/<X>')
  - Cancel
```

### Step 3: Stage and commit

Stage only files that are part of the user's intended change. Don't blanket `git add -A` — pick the modified tracked files.

Generate a clear commit message — Claude composes this from the actual file diffs:

```bash
git add <files>
git commit -m "$(cat <<'EOF'
<one-line summary, imperative voice>

<bullet list of what changed and why>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

If we're already on a `change/*` branch with an open PR, additional commits will accumulate; that's fine — the PR shows them all.

### Step 4: Push

```bash
# First push for this branch:
git push -u origin "$branch"

# Subsequent pushes (branch already tracks origin):
git push
```

### Step 5: Open or update the PR

Check whether a PR already exists for this branch:

```bash
existing=$(gh pr view "$branch" --json number,url 2>/dev/null || true)
```

If empty → create:

```bash
gh pr create --base main --head "$branch" \
  --title "<concise summary, < 70 chars>" \
  --body "$(cat <<'EOF'
## Summary

<1-3 bullets of what this PR does>

## Files changed

<list of paths with one-line per file describing the change>

## Test plan

<how the operator should verify before merging — e.g., "run /master_trading manually inside market hours and confirm no error", or "review the new strategy_<x>/SKILL.md for completeness">
EOF
)"
```

If existing → no extra action needed; the new push already updated the PR. Optionally `gh pr comment "$branch" --body "Pushed an additional commit: <summary>"` if the change is substantive enough to call out.

### Step 6: Tell the user

Print:
- The PR URL.
- The current branch they're on.
- A reminder: `main` is unchanged locally and remotely — the change is sandboxed.
- What to do next: ping the owner, wait for review.

---

## Mode 2: Sync (check PR status and merge back if approved)

### Step 1: Find the PR for the current branch

```bash
current_branch=$(git rev-parse --abbrev-ref HEAD)
case "$current_branch" in
  change/*) ;;
  *)
    echo "You're on '$current_branch', not a change/* branch. Nothing to sync."
    exit 0
    ;;
esac

pr_json=$(gh pr view "$current_branch" --json state,mergedAt,reviewDecision,number,url,title)
state=$(jq -r '.state' <<<"$pr_json")
```

### Step 2: Branch on PR state

**`MERGED`** — the owner approved and merged. Sync local repo:

```bash
git checkout main
git pull origin main
git branch -d "$current_branch"          # local delete
git push origin --delete "$current_branch" # remote delete (optional but tidy)
```

Tell the user: "PR #N merged. You're back on `main` with the latest commit `<sha>`."

**`OPEN`** — still under review. Show review state:

```bash
review=$(jq -r '.reviewDecision' <<<"$pr_json")  # APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / null
```

Translate to plain English:
- `APPROVED` → "PR has the required approvals but has not been merged yet. The owner needs to click Merge."
- `CHANGES_REQUESTED` → "Owner requested changes. Make the edits and run /change_management again to push updates."
- `REVIEW_REQUIRED` / `null` → "PR is still waiting for owner review."

**`CLOSED`** (without merge) — ask the user:

```
PR #N was closed without being merged. Options:
  - Reopen and continue (gh pr reopen)
  - Abandon this branch (delete local + remote, switch to main)
```

---

## What counts as a qualifying change (the hook's filter)

`.claude/hooks/check_design_change.sh` fires on `PostToolUse` for `Write|Edit`. It uses `git ls-files --error-unmatch <path>` to test whether the modified file is tracked. If yes, it injects a reminder for Claude.

Why "tracked" instead of an explicit allowlist: tracked files are exactly the set that affects other operators (gitignored files like `pool.json`, snapshots, `.env` are intentionally not tracked). This catches design/code/doc/baseline-config changes uniformly without maintaining a brittle path list.

The owner's own changes also flow through this — branch protection on `main` (set up via the script below) prevents direct merges from anyone, including the owner.

## Branch protection (one-time setup by the owner)

```bash
bash "$REPO_ROOT/.claude/skills/change_management/scripts/setup_branch_protection.sh"
```

Configures GitHub repo settings to:
- Require a PR before merging to `main`.
- Require at least 1 approving review.
- Dismiss stale reviews when new commits are pushed.
- Disallow direct pushes to `main`.

Owner-only. Other users won't have repo-admin permissions to run this against `khoks/ClaudeTrading`. They can fork and configure their own forks.

## Edge cases

- **Operator has uncommitted changes when switching to a change branch**: `git checkout -b` carries them along. No stash needed.
- **Operator already pushed directly to main before this skill existed**: with branch protection enabled, GitHub will reject future direct pushes. Past direct commits stay; not retroactively reviewable.
- **Multiple change branches at once**: supported. Each maintains its own PR. Sync mode operates only on the current branch.
- **Forks**: `gh pr create` against the operator's `origin` (their fork). To target upstream, they'd pass `--repo khoks/ClaudeTrading`; the skill defaults to `origin` so forks self-manage.

## Reuse

`lib/env.sh` for `$REPO_ROOT`. `gh` CLI for all PR ops. Plain git for branch / commit / push. No additional helpers needed.

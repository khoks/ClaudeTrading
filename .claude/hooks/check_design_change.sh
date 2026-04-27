#!/usr/bin/env bash
# .claude/hooks/check_design_change.sh
#
# PostToolUse hook for Write|Edit. Reads the tool's JSON envelope on stdin,
# pulls the modified file path, and emits an `additionalContext` reminder
# to the model if the path is a tracked git file (i.e., a change that
# would land in a public commit).
#
# The reminder nudges Claude to invoke /change_management at a sensible
# moment so the change goes through PR review instead of landing directly
# on main.
#
# Hook contract: must exit 0 even on error so we don't break tool calls.
# All stderr noise is suppressed.

set +e

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0

file_path=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' <<<"$input" 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Resolve relative-to-repo path. Repo root is .. from this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"
[ -z "$REPO_ROOT" ] && exit 0

case "$file_path" in
  "$REPO_ROOT"/*) rel_path="${file_path#$REPO_ROOT/}" ;;
  /*)             rel_path="$file_path" ;;     # absolute, but outside repo → bail
  *)              rel_path="$file_path" ;;     # relative — assume relative to repo
esac

# Ignore if the path resolves outside the repo.
case "$file_path" in
  "$REPO_ROOT"/*|*/) ;;
  /*) [ "${file_path#$REPO_ROOT}" = "$file_path" ] && exit 0 ;;
esac

cd "$REPO_ROOT" 2>/dev/null || exit 0

# Is it tracked? (--error-unmatch returns non-zero on untracked / gitignored.)
if ! git ls-files --error-unmatch "$rel_path" >/dev/null 2>&1; then
  exit 0
fi

# Check current branch to tailor the message.
current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

case "$current" in
  main)
    msg="Note: \`$rel_path\` is a tracked file on \`main\`. When you finish this round of edits, invoke \`/change_management\` to PR the changes for owner review (it will move you to a \`change/*\` branch and leave \`main\` clean). Direct pushes to \`main\` are blocked by branch protection."
    ;;
  change/*)
    msg="Note: \`$rel_path\` was edited on branch \`$current\`. Invoke \`/change_management\` when ready to commit + push — pushing will auto-update the existing PR."
    ;;
  *)
    # Other branches (detached HEAD, custom feature branches) — don't interfere.
    exit 0
    ;;
esac

jq -nc --arg msg "$msg" '
{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $msg
  }
}'

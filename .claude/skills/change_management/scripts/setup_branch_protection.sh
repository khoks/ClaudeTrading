#!/usr/bin/env bash
# change_management/scripts/setup_branch_protection.sh
#
# One-time setup for the repo owner. Configures GitHub branch protection
# on `main` so:
#   - A pull request is required before merging
#   - At least 1 approving review is required
#   - Stale reviews are dismissed when new commits are pushed
#   - Direct pushes to main are blocked
#
# Idempotent: re-running just re-applies the same config.
# Requires: gh CLI authenticated, with repo admin permissions on the
# target repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

cd "$REPO_ROOT"

# Resolve the GitHub owner/repo slug from the origin remote.
remote_url=$(git remote get-url origin 2>/dev/null) || {
  echo "ERROR: no origin remote configured. Run from a clone with a GitHub remote." >&2
  exit 1
}

# Extract owner/repo from URL (handles both https://github.com/o/r.git and git@github.com:o/r.git)
slug=$(printf '%s\n' "$remote_url" | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?|\1|')
if [ -z "$slug" ] || [ "$slug" = "$remote_url" ]; then
  echo "ERROR: could not parse owner/repo from origin URL: $remote_url" >&2
  exit 1
fi

echo "Configuring branch protection for $slug:main..."

# Apply the protection rules via gh api PUT.
gh api -X PUT "repos/$slug/branches/main/protection" --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON

echo
echo "Done. Branch protection applied to $slug:main:"
echo "  - PR required before merging"
echo "  - >=1 approving review required"
echo "  - Stale reviews dismissed on new commits"
echo "  - Direct pushes (including force-push) blocked"
echo
echo "To verify in browser: https://github.com/$slug/settings/branches"

#!/usr/bin/env bash
#
# Idempotent GitHub repository settings for energy-data-platform (phase 4 spec, deliverable A).
# Run by the owner, like bootstrap.sh: repository settings need the owner's GitHub rights. A gh
# script rather than Terraform's github provider, which would need a GitHub token stored as a
# secret (CLAUDE.md rule 5).
#
# Usage:
#   gh auth login
#   GITHUB_OWNER=<your-github-username-or-org> ./infra/bootstrap/github-settings.sh

set -euo pipefail

GITHUB_OWNER="${GITHUB_OWNER:?Set GITHUB_OWNER, e.g. GITHUB_OWNER=jtnOranen ./github-settings.sh}"
REPO="${GITHUB_OWNER}/energy-data-platform"

echo "==> Checking gh login"
gh auth status >/dev/null

# Squash merge only (one commit per PR on main, docs/conventions.md) and no stale branches.
echo "==> Merge settings on $REPO"
gh api --method PATCH "repos/$REPO" \
  -F allow_squash_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true \
  --silent
echo "    squash merge only, branches deleted after merge"

# Only protected branches (main) may deploy to dev, so no branch's workflow can reach the deploy
# credential (phase 4 spec, decision 4). No required reviewer: the review happens on the PR.
echo "==> Environment dev on $REPO"
gh api --method PUT "repos/$REPO/environments/dev" --input - --silent <<'JSON'
{
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
JSON
echo "    deployments only from protected branches (main)"

echo ""
echo "==> Done"

#!/bin/sh
# Fail when commits or the PR description carry Claude attribution.
# Usage: check-attribution.sh <git rev-list args>   e.g.  base..head   or   -1 <sha>
# Optional: PR_BODY env var with the pull request description.
set -eu

bad=0

for c in $(git rev-list "$@"); do
  # Parse real trailers only, so prose that mentions the words does not match.
  hits=$(git log -1 --format='%(trailers:unfold)' "$c" \
    | grep -iE '^(co-authored-by:.*noreply@anthropic\.com|claude-session:)' \
    | tr '\n' ' ' || true)
  if [ -n "$hits" ]; then
    echo "::error::Commit $(git log -1 --format='%h %s' "$c") has Claude attribution: $hits"
    bad=1
  fi
done

# Match the real footer ("🤖 Generated with [Claude Code](...)") and real session
# URLs, not prose that only mentions them.
if [ -n "${PR_BODY:-}" ] && printf '%s' "$PR_BODY" \
  | grep -qiE '🤖 *generated with \[?claude code|generated with \[claude code\]\(|https?://claude\.ai/code/[a-z0-9_-]'; then
  echo "::error::The pull request description contains Claude attribution."
  bad=1
fi

if [ "$bad" -eq 0 ]; then
  echo "No Claude attribution found."
fi
exit "$bad"

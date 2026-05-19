#!/usr/bin/env bash
# Posts a one-time PR comment when changed files fall under migrated EPP/BBR paths.
set -euo pipefail

if [[ -z "${GITHUB_REPOSITORY:-}" || -z "${PR_NUMBER:-}" ]]; then
  echo "GITHUB_REPOSITORY and PR_NUMBER must be set"
  exit 1
fi

CONFIG=".github/migrated-paths.yaml"
MARKER=$(grep '^comment_marker:' "$CONFIG" | sed 's/^comment_marker:[[:space:]]*//;s/^"//;s/"$//')
MIGRATION_ISSUE=$(grep '^migration_issue:' "$CONFIG" | sed 's/^migration_issue:[[:space:]]*//')
EPP_REPO=$(grep 'epp:' "$CONFIG" | head -1 | awk '{print $2}')
BBR_REPO=$(grep 'bbr:' "$CONFIG" | head -1 | awk '{print $2}')

PREFIXES=()
while read -r prefix; do
  PREFIXES+=("$prefix")
done < <(grep '^  - ' "$CONFIG" | awk '{print $2}')

matches_prefix() {
  local file=$1 prefix
  for prefix in "${PREFIXES[@]}"; do
    if [[ "$file" == "$prefix"* ]]; then
      return 0
    fi
  done
  return 1
}

# Collect PR files that touch migrated paths.
matched_files=()
hit_epp=false
hit_bbr=false
page=1

while true; do
  response=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files?per_page=100&page=${page}")
  count=$(echo "$response" | jq 'length')
  if [[ "$count" -eq 0 ]]; then
    break
  fi

  while IFS= read -r file; do
    if ! matches_prefix "$file"; then
      continue
    fi
    matched_files+=("$file")
    if [[ "$file" == cmd/epp/* || "$file" == pkg/epp/* ]]; then
      hit_epp=true
    fi
    if [[ "$file" == cmd/bbr/* || "$file" == pkg/bbr/* ]]; then
      hit_bbr=true
    fi
  done < <(echo "$response" | jq -r '.[].filename')

  if [[ "$count" -lt 100 ]]; then
    break
  fi
  page=$((page + 1))
done

if [[ ${#matched_files[@]} -eq 0 ]]; then
  exit 0
fi

# Skip if we already left the notice on this PR.
if gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments?per_page=100" \
  --jq '.[].body' | grep -qF "$MARKER"; then
  echo "Migration notice already on PR #${PR_NUMBER}."
  exit 0
fi

destinations=""
if [[ "$hit_epp" == true ]]; then
  destinations="${destinations}- [llm-d-inference-scheduler](${EPP_REPO}) (EPP)"$'\n'
fi
if [[ "$hit_bbr" == true ]]; then
  destinations="${destinations}- [llm-d-inference-payload-processor](${BBR_REPO}) (BBR)"$'\n'
fi

file_list=$(printf '%s\n' "${matched_files[@]}" | sort -u | head -20 | sed 's/^/- `/;s/$/`/')
extra_count=$(printf '%s\n' "${matched_files[@]}" | sort -u | wc -l | tr -d ' ')
if [[ "$extra_count" -gt 20 ]]; then
  file_list="${file_list}"$'\n'"- ... and $((extra_count - 20)) more"
fi

comment="${MARKER}

This pull request changes \`cmd/epp\`, \`pkg/epp\`, \`cmd/bbr\`, or \`pkg/bbr\`. That code has moved to llm-d; we are not cutting new releases from these paths in this repository.

Open your change in:

${destinations}
Background: ${MIGRATION_ISSUE} · [README](https://github.com/${GITHUB_REPOSITORY}/blob/main/README.md)

Changed files:
${file_list}

Maintainers: not closed by CI. Review for valid exceptions (removals, security fixes, docs) before closing."

gh pr comment "$PR_NUMBER" --body "$comment"
echo "Posted migration notice on PR #${PR_NUMBER}."

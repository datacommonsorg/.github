#!/usr/bin/env bash
# Add non-core pull requests to the Open Source Issue Triage project (#15) and
# set their "Contributor" field.
#
# Classification:
#   Bot      -> GitHub account type is "Bot" (dependabot, copybara-service, ...)
#   Core     -> current member of the datacommonsorg/core team, excluding that
#               team's robot accounts
#   External -> everyone else: partner orgs, interns, drive-by contributors
#
# Core PRs are skipped. The core roster is read from the API on every run, so
# team changes are picked up without editing this file.
#
# Only PRs that are missing from the project, or present but unstamped, are
# touched. A steady-state run makes a few dozen API calls.
#
# Requires GH_TOKEN with: read:org, project, repo
#
# Usage:
#   ./sync_project_prs.sh              # all repos
#   ./sync_project_prs.sh data mixer   # only the named repos
#   DRY_RUN=1 ./sync_project_prs.sh    # classify and report, change nothing

set -euo pipefail

ORG="datacommonsorg"
PROJECT_NUM=15
PROJECT_ID="PVT_kwDOAxm5Ts4Bjepz"
FIELD_ID="PVTSSF_lADOAxm5Ts4BjepzzhiWW4U"
OPT_EXTERNAL="a70f1dac"
OPT_BOT="77f5cb56"
DRY_RUN="${DRY_RUN:-0}"

# Robot accounts that belong to the core team but should count as bots.
CORE_ROBOTS="datcom-bot datacommons-robot-author dc-org2018"

ALL_REPOS=(
  agent-toolkit api-python data datacommons deployment-engine docsite
  import llm-tools mixer schema tools website
)
if [[ $# -gt 0 ]]; then REPOS=("$@"); else REPOS=("${ALL_REPOS[@]}"); fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- core roster, fetched live --------------------------------------------
gh api "/orgs/$ORG/teams/core/members?per_page=100" --paginate \
  --jq '.[].login' | tr 'A-Z' 'a-z' | sort -u > "$WORK/roster.txt"
for robot in $CORE_ROBOTS; do
  grep -vx "$robot" "$WORK/roster.txt" > "$WORK/roster.tmp" || true
  mv "$WORK/roster.tmp" "$WORK/roster.txt"
done
echo "core roster: $(wc -l < "$WORK/roster.txt" | tr -d ' ') humans"

# --- what is already in the project ---------------------------------------
# "<url> <TAB> <Contributor value or -->" for every item.
gh api graphql --paginate -f query='
  query($endCursor: String) {
    organization(login: "'"$ORG"'") {
      projectV2(number: '"$PROJECT_NUM"') {
        items(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            content { ... on PullRequest { url } }
            fieldValueByName(name: "Contributor") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
          }
        }
      }
    }
  }' \
  --jq '.data.organization.projectV2.items.nodes[]
        | select(.content.url != null)
        | "\(.content.url)\t\(.id)\t\(.fieldValueByName.name // "-")"' \
  > "$WORK/existing.txt"
echo "project already tracks $(wc -l < "$WORK/existing.txt" | tr -d ' ') pull requests"
echo

added=0; stamped=0; skipped_core=0; unchanged=0; failed=0

for repo in "${REPOS[@]}"; do
  prs=$(gh api "/repos/$ORG/$repo/pulls?state=open&per_page=100" --paginate \
        --jq '.[] | "\(.html_url)\t\(.user.login | ascii_downcase)\t\(.user.type)"' \
        2>/dev/null || true)
  [[ -z "$prs" ]] && continue

  repo_added=0; repo_stamped=0
  while IFS=$'\t' read -r url login utype; do
    [[ -z "$url" ]] && continue

    # classify
    if [[ "$utype" == "Bot" ]] || printf '%s\n' $CORE_ROBOTS | grep -qx "$login"; then
      want="Bot"; opt="$OPT_BOT"
    elif grep -qx "$login" "$WORK/roster.txt"; then
      skipped_core=$((skipped_core + 1)); continue
    else
      want="External"; opt="$OPT_EXTERNAL"
    fi

    line=$(grep -F "$url	" "$WORK/existing.txt" || true)
    item_id="";  current=""
    if [[ -n "$line" ]]; then
      item_id=$(cut -f2 <<< "$line")
      current=$(cut -f3 <<< "$line")
    fi

    # already correct
    if [[ "$current" == "$want" ]]; then unchanged=$((unchanged + 1)); continue; fi

    if [[ "$DRY_RUN" == "1" ]]; then
      if [[ -z "$item_id" ]]; then echo "  [dry-run] add+stamp $want  $url"
      else echo "  [dry-run] stamp $want (was ${current:--})  $url"; fi
      continue
    fi

    if [[ -z "$item_id" ]]; then
      item_id=$(gh project item-add "$PROJECT_NUM" --owner "$ORG" --url "$url" \
                --format json --jq '.id' 2>/dev/null || true)
      if [[ -z "$item_id" ]]; then
        echo "  FAILED to add: $url" >&2; failed=$((failed + 1)); continue
      fi
      added=$((added + 1)); repo_added=$((repo_added + 1))
    fi

    if gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" \
         --field-id "$FIELD_ID" --single-select-option-id "$opt" >/dev/null 2>&1; then
      stamped=$((stamped + 1)); repo_stamped=$((repo_stamped + 1))
    else
      echo "  FAILED to stamp: $url" >&2; failed=$((failed + 1))
    fi
  done <<< "$prs"

  if (( repo_added > 0 || repo_stamped > 0 )); then
    echo "$repo: +$repo_added added, $repo_stamped stamped"
  fi
done

echo
echo "added $added, stamped $stamped, core skipped $skipped_core, already correct $unchanged, failed $failed"
[[ "$failed" -gt 0 ]] && exit 1
exit 0

#!/usr/bin/env bash
#
# Keeps the "Data Commons Issue & Pull-Request Triage" project stocked with pull requests that
# did not come from the core team.
#   https://github.com/orgs/datacommonsorg/projects/15
#
# Every open PR across the public repos is classified by its author:
#
#   Bot       GitHub account type is "Bot" (dependabot, copybara-service), or
#             one of the robot accounts that sit inside the core team
#   Core      current member of the datacommonsorg/core team
#   External  everyone else: partner orgs, interns, drive-by contributors
#
# External and Bot PRs are added to the project with the "Contributor" field
# set. Core PRs are left out. The team roster is read from the API on every
# run, so adding someone to the core team is enough to stop tracking them.
#
# The script compares against what the project already holds, so it is safe to
# run repeatedly: a run with nothing new to do makes about 20 API calls and
# writes nothing.
#
# Needs GH_TOKEN with: read:org, project, repo
#
# Usage:
#   ./sync_project_prs.sh              # every repo
#   ./sync_project_prs.sh data mixer   # just these
#   DRY_RUN=1 ./sync_project_prs.sh    # report, change nothing

set -euo pipefail

ORG="datacommonsorg"
PROJECT_NUMBER=15          # "Data Commons Issue & Pull-Request Triage"
FIELD_NAME="Contributor"
TEAM="core"
DRY_RUN="${DRY_RUN:-0}"

# Robot accounts that are members of the core team but should count as bots.
# They are ordinary user accounts, so the account-type check cannot catch them.
CORE_ROBOTS="datcom-bot datacommons-robot-author dc-org2018"

REPOS=(
  agent-toolkit api-python data datacommons deployment-engine docsite
  import llm-tools mixer schema tools website
)
[[ $# -gt 0 ]] && REPOS=("$@")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Resolve the project and the Contributor field by name, so this script has no
# opaque node IDs baked into it and keeps working if the field is recreated.
# ---------------------------------------------------------------------------
gh api graphql -f query='
  query {
    organization(login: "'"$ORG"'") {
      projectV2(number: '"$PROJECT_NUMBER"') {
        id
        title
        field(name: "'"$FIELD_NAME"'") {
          ... on ProjectV2SingleSelectField { id options { id name } }
        }
      }
    }
  }' --jq '.data.organization.projectV2
           | "PROJECT_ID=\(.id | @sh)", "PROJECT_TITLE=\(.title | @sh)",
             "FIELD_ID=\(.field.id | @sh)",
             (.field.options[] | "OPTION_\(.name | ascii_upcase)=\(.id | @sh)")' \
  > "$WORK/ids.env"
source "$WORK/ids.env"


if [[ -z "${FIELD_ID:-}" || -z "${OPTION_EXTERNAL:-}" || -z "${OPTION_BOT:-}" ]]; then
  echo "Could not find the \"$FIELD_NAME\" single-select field on \"$PROJECT_TITLE\"." >&2
  echo "It needs options named Core, External and Bot." >&2
  exit 1
fi
echo "project: $PROJECT_TITLE (#$PROJECT_NUMBER)"

# ---------------------------------------------------------------------------
# Current core team roster.
# ---------------------------------------------------------------------------
gh api "/orgs/$ORG/teams/$TEAM/members?per_page=100" --paginate \
  --jq '.[].login | ascii_downcase' | sort -u > "$WORK/roster.txt"
printf '%s\n' $CORE_ROBOTS | sort -u > "$WORK/robots.txt"
echo "roster:  $(wc -l < "$WORK/roster.txt" | tr -d ' ') members of @$ORG/$TEAM"

# ---------------------------------------------------------------------------
# Pull requests the project already holds, with their current field value.
#   url <TAB> item id <TAB> Contributor value (or "-")
# Issues come back with an empty content object and are filtered out.
# ---------------------------------------------------------------------------
gh api graphql --paginate -f query='
  query($endCursor: String) {
    organization(login: "'"$ORG"'") {
      projectV2(number: '"$PROJECT_NUMBER"') {
        items(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            content { ... on PullRequest { url } }
            fieldValueByName(name: "'"$FIELD_NAME"'") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
          }
        }
      }
    }
  }' \
  --jq '.data.organization.projectV2.items.nodes[]
        | select(.content.url != null)
        | [.content.url, .id, (.fieldValueByName.name // "-")] | @tsv' \
  > "$WORK/tracked.tsv"
echo "tracked: $(wc -l < "$WORK/tracked.tsv" | tr -d ' ') pull requests already in the project"
echo

classify() {  # login, account type -> Core | External | Bot
  if [[ "$2" == "Bot" ]] || grep -qx "$1" "$WORK/robots.txt"; then
    echo Bot
  elif grep -qx "$1" "$WORK/roster.txt"; then
    echo Core
  else
    echo External
  fi
}

added=0 stamped=0 core=0 ok=0 failed=0

for repo in "${REPOS[@]}"; do
  gh api "/repos/$ORG/$repo/pulls?state=open&per_page=100" --paginate \
    --jq '.[] | [.html_url, (.user.login | ascii_downcase), .user.type] | @tsv' \
    > "$WORK/prs.tsv" 2>/dev/null || continue

  while IFS=$'\t' read -r url login type; do
    [[ -z "$url" ]] && continue

    want="$(classify "$login" "$type")"
    if [[ "$want" == "Core" ]]; then core=$((core + 1)); continue; fi

    # What the project currently knows about this PR, if anything. read exits
    # non-zero when awk finds no match, which must not trip set -e.
    item_id="" current=""
    IFS=$'\t' read -r item_id current < <(
      awk -F'\t' -v u="$url" '$1 == u { print $2 "\t" $3; exit }' "$WORK/tracked.tsv"
    ) || true


    [[ "$current" == "$want" ]] && { ok=$((ok + 1)); continue; }

    if [[ "$DRY_RUN" == "1" ]]; then
      if [[ -z "$item_id" ]]; then echo "  would add    $want  $url"
      else                         echo "  would stamp  $want  $url"; fi
      continue
    fi

    if [[ -z "$item_id" ]]; then
      item_id="$(gh project item-add "$PROJECT_NUMBER" --owner "$ORG" --url "$url" \
                 --format json --jq '.id')" || item_id=""
      if [[ -z "$item_id" ]]; then
        echo "  could not add $url" >&2; failed=$((failed + 1)); continue
      fi
      added=$((added + 1))
    fi

    eval "option=\$OPTION_$(echo "$want" | tr '[:lower:]' '[:upper:]')"
    if gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" \
         --field-id "$FIELD_ID" --single-select-option-id "$option" >/dev/null; then
      stamped=$((stamped + 1))
    else
      echo "  could not set $FIELD_NAME on $url" >&2; failed=$((failed + 1))
    fi
  done < "$WORK/prs.tsv"
done

echo "added $added, stamped $stamped, already correct $ok, core skipped $core, failed $failed"
[[ "$failed" -eq 0 ]]

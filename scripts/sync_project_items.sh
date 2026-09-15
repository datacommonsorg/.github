#!/usr/bin/env bash
#
# Keeps the "Data Commons Issue & Pull-Request Triage" project stocked with the
# open issues and pull requests from the public repos, each tagged with who
# opened it.
#   https://github.com/orgs/datacommonsorg/projects/15
#
# Authors are classified as:
#
#   Bot       GitHub account type is "Bot" (dependabot, copybara-service), or
#             one of the robot accounts that sit inside the core team
#   Core      current member of the datacommonsorg/core team
#   External  everyone else: partner orgs, interns, drive-by contributors
#
# The roster is read from the API on every run, so moving someone onto the core
# team is enough to change how their work is tagged from then on.
#
# Issues also arrive through the project's own auto-add workflows, which are
# instant but cannot set a field. This script tags whatever they added, and
# covers the repos that have no auto-add workflow.
#
# The script compares against what the project already holds, so it is safe to
# run repeatedly and safe to interrupt. A run with nothing to do writes nothing,
# and a run that stops halfway is finished by the next one.
#
# Needs GH_TOKEN with: read:org, project, repo
#
# Usage:
#   ./sync_project_items.sh                    # every repo
#   ./sync_project_items.sh data mixer         # just these
#   DRY_RUN=1 ./sync_project_items.sh          # report, change nothing
#   WAIT_FOR_BUDGET=1 ./sync_project_items.sh  # sleep through a rate limit
#                                              # instead of stopping early

set -euo pipefail

ORG="datacommonsorg"
PROJECT_NUMBER=15          # "Data Commons Issue & Pull-Request Triage"
FIELD_NAME="Contributor"
TEAM="core"
DRY_RUN="${DRY_RUN:-0}"
WAIT_FOR_BUDGET="${WAIT_FOR_BUDGET:-0}"

# Robot accounts that are members of the core team but should count as bots.
# They are ordinary user accounts, so the account-type check cannot catch them.
CORE_ROBOTS=(datcom-bot datacommons-robot-author dc-org2018)

REPOS=(
  agent-toolkit api-python data datacommons deployment-engine docsite
  import llm-tools mixer schema tools website
)
[[ $# -gt 0 ]] && REPOS=("$@")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Rate limits.
#
# GitHub bills project writes against an hourly GraphQL point budget, and a
# backfill goes through it fast: roughly 200 items is the whole hour. Two
# things make this hard to spot. REST /rate_limit reports a different, much
# rosier figure than the GraphQL one, and `gh project item-add` renders an
# exhausted budget as "unknown owner type", which looks like malformed input.
# So: never trust the error text, ask GraphQL for the real number.
#
# Because the script resumes cleanly, running out of budget is not an error.
# By default it stops and lets the next scheduled run continue.
# ---------------------------------------------------------------------------
BUDGET_FLOOR=60            # points left at which we stop starting new writes
BUDGET_STALLED=""
LAST_ERROR=""

budget_remaining() {  # querying the budget is itself free
  gh api graphql -f query='{ rateLimit { remaining } }' \
    --jq '.data.rateLimit.remaining' 2>/dev/null || echo 9999
}

sleep_until_reset() {
  local at now reset wait
  at="$(gh api graphql -f query='{ rateLimit { resetAt } }' \
        --jq '.data.rateLimit.resetAt' 2>/dev/null)" || at=""
  now="$(date -u +%s)"
  # BSD and GNU date disagree on how to parse a timestamp; try both.
  reset="$(date -u -d "$at" +%s 2>/dev/null \
           || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$at" +%s 2>/dev/null \
           || echo $((now + 300)))"
  wait=$((reset - now + 10))
  ((wait < 10)) && wait=10
  echo "  GraphQL budget exhausted, waiting $((wait / 60))m for reset" >&2
  sleep "$wait"
}

# Run a write, retrying if it failed only because the budget ran out.
retry_write() {
  local attempt=0
  while :; do
    if "$@" >"$WORK/out" 2>"$WORK/err"; then cat "$WORK/out"; return 0; fi
    LAST_ERROR="$(tr '\n' ' ' <"$WORK/err" | sed 's/  */ /g; s/ $//')"
    attempt=$((attempt + 1))

    # A real failure, or we have retried enough.
    if [[ "$(budget_remaining)" -ge "$BUDGET_FLOOR" || $attempt -ge 3 ]]; then
      return 1
    fi
    if [[ "$WAIT_FOR_BUDGET" != "1" ]]; then BUDGET_STALLED=1; return 1; fi
    sleep_until_reset
  done
}

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

if [[ -z "${FIELD_ID:-}" || -z "${OPTION_CORE:-}" \
   || -z "${OPTION_EXTERNAL:-}" || -z "${OPTION_BOT:-}" ]]; then
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
echo "roster:  $(wc -l < "$WORK/roster.txt" | tr -d ' ') members of @$ORG/$TEAM"

# Membership is tested once per item, so keep the lookups in the shell rather
# than spawning grep a few thousand times. GitHub logins cannot contain
# spaces, so space-delimited containment is an exact match.
ROSTER=" $(tr '\n' ' ' < "$WORK/roster.txt") "
ROBOTS=" ${CORE_ROBOTS[*]} "

# ---------------------------------------------------------------------------
# What the project already holds, with each item's current field value.
#   url <TAB> item id <TAB> Contributor value (or "-")
# Draft issues have no url and drop out here.
# ---------------------------------------------------------------------------
gh api graphql --paginate -f query='
  query($endCursor: String) {
    organization(login: "'"$ORG"'") {
      projectV2(number: '"$PROJECT_NUMBER"') {
        items(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            content {
              ... on Issue { url }
              ... on PullRequest { url }
            }
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
echo "tracked: $(wc -l < "$WORK/tracked.tsv" | tr -d ' ') items already in the project"
echo

classify() {  # login, account type -> Core | External | Bot
  if [[ "$2" == "Bot" || "$ROBOTS" == *" $1 "* ]]; then
    echo Bot
  elif [[ "$ROSTER" == *" $1 "* ]]; then
    echo Core
  else
    echo External
  fi
}

added=0 stamped=0 ok=0 failed=0 unlisted=0

# The issues endpoint returns pull requests as well, and pulls responses have
# no .pull_request key, so this one filter both de-duplicates the issues list
# and passes every pull request through.
ITEM_JQ='.[] | select(.pull_request == null)
         | [.html_url, (.user.login | ascii_downcase), .user.type] | @tsv'

for repo in "${REPOS[@]}"; do
  : > "$WORK/items.tsv"
  for endpoint in issues pulls; do
    # Errors are deliberately left on stderr. Hiding them would make a repo we
    # cannot read look identical to a repo with nothing open, and the board
    # would quietly go stale for it.
    if ! gh api "/repos/$ORG/$repo/$endpoint?state=open&per_page=100" --paginate \
           --jq "$ITEM_JQ" >> "$WORK/items.tsv"; then
      echo "  could not list $endpoint for $repo" >&2
      unlisted=$((unlisted + 1))
    fi
  done

  while IFS=$'\t' read -r url login type; do
    [[ -z "$url" ]] && continue

    want="$(classify "$login" "$type")"

    # What the project currently knows about this item, if anything. read exits
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
      if ! item_id="$(retry_write gh project item-add "$PROJECT_NUMBER" \
                      --owner "$ORG" --url "$url" --format json --jq '.id')"; then
        [[ -n "$BUDGET_STALLED" ]] && break 2
        echo "  could not add $url: $LAST_ERROR" >&2
        failed=$((failed + 1)); continue
      fi
      added=$((added + 1))
    fi

    eval "option=\$OPTION_$(echo "$want" | tr '[:lower:]' '[:upper:]')"
    if retry_write gh project item-edit --id "$item_id" \
         --project-id "$PROJECT_ID" --field-id "$FIELD_ID" \
         --single-select-option-id "$option" >/dev/null; then
      stamped=$((stamped + 1))
    else
      [[ -n "$BUDGET_STALLED" ]] && break 2
      echo "  could not set $FIELD_NAME on $url: $LAST_ERROR" >&2
      failed=$((failed + 1))
    fi
  done < "$WORK/items.tsv"
done

echo "added $added, stamped $stamped, already correct $ok, failed $failed"

if [[ "$unlisted" -gt 0 ]]; then
  echo "$unlisted repo listing(s) could not be read; those repos are incomplete."
fi

if [[ -n "$BUDGET_STALLED" ]]; then
  echo
  echo "Stopped early: the hourly GraphQL budget ran out. The remaining items"
  echo "will be picked up by the next run. Pass WAIT_FOR_BUDGET=1 to sit and"
  echo "wait for the reset instead."
fi

# Running out of budget is normal and resumes next run, so it is not a failure.
# A write that failed, or a repo we could not read, is.
[[ "$failed" -eq 0 && "$unlisted" -eq 0 ]]

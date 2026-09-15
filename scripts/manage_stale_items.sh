#!/usr/bin/env bash
#
# Automated stale issue and pull request management across Data Commons public
# repositories.
#
# Policy:
#   1. Warning (90 days): Open issues or PRs with no activity for WARN_DAYS
#      receive a polite comment and the "stale" label.
#   2. Auto-close (30 days after warning): Items with the "stale" label that
#      have had no activity for CLOSE_DAYS (120+ days total) are closed with a
#      friendly invitation to reopen if still relevant.
#   3. Un-stale: If someone comments or updates a "stale" item after the
#      warning comment, the "stale" label is automatically removed.
#   4. Exemptions: Items with an active milestone or any exempt label
#      (keep-open, pinned, security) are skipped.
#
# Usage:
#   ./scripts/manage_stale_items.sh                  # all repos
#   ./scripts/manage_stale_items.sh mixer website    # specific repos
#   DRY_RUN=1 ./scripts/manage_stale_items.sh        # preview actions only

set -euo pipefail

ORG="datacommonsorg"
WARN_DAYS="${WARN_DAYS:-90}"
CLOSE_DAYS="${CLOSE_DAYS:-30}"
STALE_LABEL="stale"
EXEMPT_LABELS=("keep-open" "pinned" "security")
DRY_RUN="${DRY_RUN:-0}"
# Cap comment/state writes per run to avoid GitHub secondary rate limits.
MAX_WRITES="${MAX_WRITES:-150}"

REPOS=(
  agent-toolkit api-python data datacommons deployment-engine docsite
  import llm-tools mixer schema tools website
)
[[ $# -gt 0 ]] && REPOS=("$@")

MARKER="<!-- datacommons-stale-warning -->"

WARN_BODY="This issue or pull request has had no activity for ${WARN_DAYS} days and has been marked as \`${STALE_LABEL}\`. Is this still relevant?

If there is no activity in the next ${CLOSE_DAYS} days, it will be closed automatically. Leave a comment or apply the \`keep-open\` label if you would like to keep it open.
${MARKER}"

CLOSE_BODY="Closing this issue or pull request automatically because it has had no activity for ${CLOSE_DAYS} days since being marked \`${STALE_LABEL}\`.

If this is still relevant, please feel free to reopen it or leave a comment and we will take a look."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NOW_EPOCH="$(date -u +%s)"

iso_to_epoch() {
  local iso="$1"
  date -u -d "$iso" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null \
    || echo "$NOW_EPOCH"
}

ensure_stale_label() {
  local repo="$1"
  if [[ "$DRY_RUN" == "1" ]]; then return 0; fi
  # Create label if it does not exist; ignore 422 if already present.
  gh api --method POST "/repos/$ORG/$repo/labels" \
    -f name="$STALE_LABEL" \
    -f color="ededed" \
    -f description="No activity for ${WARN_DAYS}+ days" \
    >/dev/null 2>&1 || true
}

warned=0
closed=0
unstaled=0
exempt=0
active=0
writes=0
unlisted=0

# Extract: number <TAB> html_url <TAB> updated_at <TAB> has_milestone <TAB> labels_csv
ITEM_JQ='.[] | [
  .number,
  .html_url,
  .updated_at,
  (if .milestone != null then "yes" else "no" end),
  ([.labels[].name | ascii_downcase] | join(","))
] | @tsv'

for repo in "${REPOS[@]}"; do
  : > "$WORK/items.tsv"
  if ! gh api "/repos/$ORG/$repo/issues?state=open&per_page=100" --paginate \
         --jq "$ITEM_JQ" >> "$WORK/items.tsv"; then
    echo "  could not list items for $repo" >&2
    unlisted=$((unlisted + 1))
    continue
  fi

  ensure_stale_label "$repo"

  while IFS=$'\t' read -r num url updated_at has_milestone labels_csv; do
    [[ -z "$num" ]] && continue

    # 1. Check milestone exemption
    if [[ "$has_milestone" == "yes" ]]; then
      exempt=$((exempt + 1))
      continue
    fi

    # 2. Check label exemptions and current stale status
    is_exempt=0
    has_stale=0
    padded_labels=",$labels_csv,"
    for ex in "${EXEMPT_LABELS[@]}"; do
      if [[ "$padded_labels" == *",$ex,"* ]]; then
        is_exempt=1
        break
      fi
    done
    if [[ "$is_exempt" -eq 1 ]]; then
      exempt=$((exempt + 1))
      continue
    fi
    if [[ "$padded_labels" == *",$STALE_LABEL,"* ]]; then
      has_stale=1
    fi

    upd_epoch="$(iso_to_epoch "$updated_at")"
    age_days=$(( (NOW_EPOCH - upd_epoch) / 86400 ))

    # 3. Item already has the stale label
    if [[ "$has_stale" -eq 1 ]]; then
      if [[ "$age_days" -ge "$CLOSE_DAYS" ]]; then
        if [[ "$DRY_RUN" == "1" ]]; then
          echo "  would close (${age_days}d since stale)  $url"
          closed=$((closed + 1))
          continue
        fi
        if [[ "$writes" -ge "$MAX_WRITES" ]]; then
          echo "Reached MAX_WRITES ($MAX_WRITES); stopping to respect rate limits."
          break 2
        fi
        gh api --method POST "/repos/$ORG/$repo/issues/$num/comments" \
          -f body="$CLOSE_BODY" >/dev/null
        gh api --method PATCH "/repos/$ORG/$repo/issues/$num" \
          -f state="closed" -f state_reason="not_planned" >/dev/null
        echo "  closed (${age_days}d since stale)  $url"
        closed=$((closed + 1))
        writes=$((writes + 1))
        sleep 1
      else
        # Check if updated after the warning comment by someone else
        last_body="$(gh api "/repos/$ORG/$repo/issues/$num/comments?per_page=1&direction=desc" \
                       --jq '.[0].body // ""' 2>/dev/null || echo "")"
        if [[ -n "$last_body" && "$last_body" != *"$MARKER"* ]]; then
          if [[ "$DRY_RUN" == "1" ]]; then
            echo "  would un-stale (new activity)  $url"
            unstaled=$((unstaled + 1))
            continue
          fi
          gh api --method DELETE "/repos/$ORG/$repo/issues/$num/labels/$STALE_LABEL" \
            >/dev/null 2>&1 || true
          echo "  un-staled (new activity)  $url"
          unstaled=$((unstaled + 1))
          writes=$((writes + 1))
        else
          active=$((active + 1))
        fi
      fi
      continue
    fi

    # 4. Item does not have the stale label yet
    if [[ "$age_days" -ge "$WARN_DAYS" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "  would warn (${age_days}d inactive)  $url"
        warned=$((warned + 1))
        continue
      fi
      if [[ "$writes" -ge "$MAX_WRITES" ]]; then
        echo "Reached MAX_WRITES ($MAX_WRITES); stopping to respect rate limits."
        break 2
      fi
      gh api --method POST "/repos/$ORG/$repo/issues/$num/comments" \
        -f body="$WARN_BODY" >/dev/null
      gh api --method POST "/repos/$ORG/$repo/issues/$num/labels" \
        -f "labels[]=$STALE_LABEL" >/dev/null
      echo "  warned (${age_days}d inactive)  $url"
      warned=$((warned + 1))
      writes=$((writes + 1))
      sleep 1
    else
      active=$((active + 1))
    fi
  done < "$WORK/items.tsv"
done

echo
echo "warned $warned, closed $closed, un-staled $unstaled, exempt $exempt, active $active"
[[ "$unlisted" -eq 0 ]]

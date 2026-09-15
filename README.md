# datacommonsorg/.github

Org-level defaults and automation for the Data Commons GitHub organization.

| Path | What it does |
| --- | --- |
| `SECURITY.md` | Security policy. GitHub falls back to this for every repo in the org that has no `SECURITY.md` of its own. |
| `scripts/sync_project_items.sh` | Keeps the triage project stocked and tagged. |
| `.github/workflows/sync-project-items.yml` | Runs that script every 30 minutes. |

> [!NOTE]
> A `README.md` at the root of this repo is just this repo's readme. The org's public profile page comes from `profile/README.md`, which does not exist here. Don't move this file there.

## The triage sync

[Data Commons Issue & Pull-Request Triage](https://github.com/orgs/datacommonsorg/projects/15) collects open issues and pull requests from the 12 public repos so nothing from outside the team goes unanswered.

The board needs to separate community work from our own. Projects can't do that alone: view filters have no `author` qualifier, and the auto-add filter only supports `is`, `label`, `reason`, `assignee` and `no`. So the sync writes the author into a `Contributor` field, and the views filter on that.

Every open issue and PR is tagged one of:

| Value | Who |
| --- | --- |
| `Core` | current member of the [`datacommonsorg/core`](https://github.com/orgs/datacommonsorg/teams/core) team |
| `Bot` | GitHub account type `Bot`, plus the robot accounts that sit inside the core team |
| `External` | everyone else: partner orgs, interns, drive-by contributors |

Issues also reach the board instantly through the project's own auto-add workflows, but those can't set a field, so the sync tags whatever they added. Pull requests depend on the sync entirely.

State lives in the project, not on disk. Each run diffs against the board, so it's idempotent and safe to interrupt.

```bash
./scripts/sync_project_items.sh                    # every repo
./scripts/sync_project_items.sh data mixer         # just these
DRY_RUN=1 ./scripts/sync_project_items.sh          # report, change nothing
WAIT_FOR_BUDGET=1 ./scripts/sync_project_items.sh  # sit through rate limits
```

## Routine tasks

### Someone joins or leaves the team

**Nothing to edit here.** Add them to the `datacommonsorg/core` team and the sync picks it up on the next run. The roster is read from the API every time and never cached.

> [!IMPORTANT]
> Tagging is recomputed, not recorded. When someone joins the core team, their existing open items get re-tagged from `External` to `Core` on the next run, and the reverse when they leave. The board always reflects who is on the team *now*, not who they were when they filed. Expect a burst of writes after a team change.

### A contractor or partner starts

Decide whether their work should read as ours or as community, because there's no third option today.

- **In the `core` team:** tagged `Core`. But that team grants repo access, so you're deciding permissions at the same time.
- **Not in the team:** tagged `External`, and their work inflates the community-contribution numbers the board exists to measure.

The `core` team is doing double duty as an access-control group and a reporting category. If that becomes a problem, the fix is a separate team for classification, which is a small change to `TEAM` in the script.

### A new bot or service account appears

If it's a real GitHub App, the account type is `Bot` and it's handled automatically.

If it's an ordinary user account acting as a robot, add it to `CORE_ROBOTS` in the script. Currently `datcom-bot`, `datacommons-robot-author`, `dc-org2018`. Miss this and it gets tagged `Core` or `External` and pollutes the human numbers.

### A new repo joins the org

Two steps:

1. Add it to the `REPOS` array in the script.
2. For instant issue pickup, add an auto-add workflow in the project UI: **Workflows** → **Auto-add to project** → filter `is:issue`. There's no API for this. It's optional, since the sync collects issues anyway, just on a 30 minute delay rather than instantly.

Auto-add workflows are capped at 20 per project. 11 are in use.

### The token expires

`PROJECT_SYNC_TOKEN` is a repo secret: a classic PAT with `read:org`, `project`, `repo`. The default `GITHUB_TOKEN` can't read team membership or write to org projects.

```bash
gh secret set PROJECT_SYNC_TOKEN --repo datacommonsorg/.github
```

> [!WARNING]
> When it expires the sync fails every 30 minutes and nothing tells anyone. The board just quietly stops updating. Until there's failure alerting, check the Actions tab if the board looks stale.

The token belongs to whoever created it, so the sync dies if that person leaves. A team-owned bot account is the durable fix.

## Things that will bite you

**Rate limits are misreported.** Project writes bill against an hourly GraphQL budget, roughly 200 items. `gh project item-add` renders an exhausted budget as `unknown owner type`, which looks like malformed input, and REST `/rate_limit` reports a completely different number from the GraphQL one. Trust only `gh api graphql -f query='{ rateLimit { remaining } }'`. The script already does.

Running out isn't a failure. The job stops and the next run resumes, which is how a several-hundred-item backfill completes on its own.

**Insights charts have no API.** No mutations, no read fields. Every chart is clicked by hand and can't be reviewed, version-controlled, or restored.

**Archiving erases chart history.** Insights ignores archived items retroactively, so auto-archiving closed items to keep the board tidy silently rewrites your trend data. Pick one.

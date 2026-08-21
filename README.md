# tech-support-tickets
Place to manage all tech support tickets with clients. There are also extensions for Slack to open and close tickets without leaving Slack.

Click [here](https://github.com/culturecreates/tech-support-tickets/issues/new/choose) to open a ticket.

You can also [view](https://github.com/culturecreates/tech-support-tickets/issues) open tickets.


# Utilities

This repo also contains support utilities:
- [Check-Suspended-Scheduled-Workflows](https://github.com/culturecreates/culture-creates-wiki/wiki/Check-Suspended-Scheduled-Workflows/) 


# Workflow health report

A monthly report that tracks failed GitHub Actions workflow runs across the `culturecreates` and `artsdata-stewards` organizations, so recurring pipeline problems are easy to spot.

## How it works

Repositories that use the shared [`artsdata-pipeline-action`](https://github.com/culturecreates/artsdata-pipeline-action) upload a `result.json` artifact (named `pipeline-result-*`) **whenever a run fails**. This report collects those artifacts and turns them into a readable summary:

1. **Collect** — `workflow_health_report/collect_and_aggregate.rb` lists each repo's `pipeline-result-*` artifacts from the last ~month, downloads them, and appends the failure records to `data/workflow_runs.jsonl` (append-only, deduplicated by `run_id`). It also records the **total number of workflow runs** per repo per month in `data/run_totals.json`, which is used as the denominator for failure rates.
2. **Build** — `workflow_health_report/build_report.rb` reads that data and writes a Markdown report to `reports/<YYYY-MM>.md`, containing:
   - **Failure rate by month** — failed runs ÷ total runs
   - **Failure rate by repo** — which repositories fail most
   - **Top failure categories** — the most common failure types (with HTTP status where available)

## Schedule

Runs automatically on the 1st of each month (06:00 UTC) via [`.github/workflows/monthly_report.yml`](.github/workflows/monthly_report.yml), and can also be triggered manually from the Actions tab (`workflow_dispatch`). The generated data and reports are committed back to this repository.

## Where is the report?

Everything the job produces is committed back into this repository:

- **Reports** — `reports/<YYYY-MM>.md` (one Markdown file per month, e.g. `reports/2026-08.md`). This is the human-readable summary.

## How to generate the report

**Automatically** — it runs on the monthly schedule with no action needed.

**On demand (recommended)** — go to the repo's **Actions** tab → **Workflow health report** → **Run workflow**. This runs the full pipeline and commits the updated data and report.

**Locally** — for testing or a one-off run:

```bash
bundle install
export GH_TOKEN=<a token with read access to Actions data in both orgs>
bundle exec ruby workflow_health_report/collect_and_aggregate.rb   # fetch + update data/
bundle exec ruby workflow_health_report/build_report.rb            # write reports/<YYYY-MM>.md
```

`build_report.rb` also prints the report to stdout, so you can preview it in the terminal.

## How to view the report

- **On GitHub** — open the `reports/` folder and click the month you want; GitHub renders the Markdown directly.
- **Direct link** — `https://github.com/culturecreates/tech-support-tickets/blob/main/reports/<YYYY-MM>.md`
- **Locally** — open the `reports/<YYYY-MM>.md` file in any Markdown viewer or editor.

## Configuration

- **`WORKFLOW_HEALTH_TOKEN`** — a repository secret holding a GitHub token with **read** access to Actions data (artifacts and workflow runs) in both organizations. A classic PAT with the `repo` scope covers both orgs; fine-grained PATs are single-org and would need one token per organization.
- **Cadence** — adjustable via the `cron` expression in the workflow file.

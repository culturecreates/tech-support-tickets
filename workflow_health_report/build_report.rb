# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

DATA_FILE = "data/workflow_runs.jsonl"
TOTALS_FILE = "data/run_totals.json"

rows = File.exist?(DATA_FILE) ? File.readlines(DATA_FILE).map { |l| JSON.parse(l) } : []
# { "org/repo" => { "YYYY-MM" => total_runs } } — the denominator for failure rates.
totals = File.exist?(TOTALS_FILE) ? JSON.parse(File.read(TOTALS_FILE)) : {}

failures = rows.select { |r| r["result"] == "failure" }

def month_of(row)
  row["started_at"] ? row["started_at"][0, 7] : "unknown"
end

def run_url(row)
  return nil unless row["org"] && row["repo"] && row["run_id"]

  "https://github.com/#{row['org']}/#{row['repo']}/actions/runs/#{row['run_id']}"
end

def failure_label(row)
  suffix = row["http_status"] ? " (HTTP #{row['http_status']})" : ""
  "`#{row['failure_category'] || 'unknown'}`#{suffix}"
end

# Total runs across all repos for a given month (used for the trend section).
total_runs_for_month = Hash.new(0)
totals.each_value do |months|
  months.each { |month, count| total_runs_for_month[month] += count }
end

# --- Determine the reporting period ---
# The job runs a couple of days into the new month, so "now" isn't the right
# period to report on - use the most recent month that actually has data.
# This is what "this period" means everywhere below: the most recently
# completed month the collector has data for, not literally all history in
# the file (which keeps growing since it's committed to git, independent of
# how long the underlying GitHub artifacts themselves are retained).
all_months = (failures.map { |r| month_of(r) } + total_runs_for_month.keys).reject { |m| m == "unknown" }
current_period = all_months.max || Time.now.utc.strftime("%Y-%m")

failures_this_period = failures.select { |r| month_of(r) == current_period }

lines = ["# Workflow health report — #{current_period}", ""]
lines << "Covers workflow runs from **#{current_period}**. Once a failure is fixed, it stops appearing here the following month — this report is not a lifetime failure log."
lines << ""

# --- 1. Failed workflows this period: the actionable list ---
lines << "## Failed workflows this period"
lines << ""
if failures_this_period.empty?
  lines << "No failures recorded this period."
else
  lines << "| Repo | Workflow | Failure | When (UTC) | Logs |"
  lines << "|---|---|---|---|---|"
  failures_this_period
    .sort_by { |r| r["started_at"] || "" }
    .reverse_each do |r|
      repo = r["org"] && r["repo"] ? "#{r['org']}/#{r['repo']}" : (r["repo"] || "unknown")
      workflow = r["workflow"] || "unknown"
      when_str = r["started_at"] || "unknown"
      url = run_url(r)
      log_link = url ? "[View logs](#{url})" : "n/a"
      lines << "| #{repo} | #{workflow} | #{failure_label(r)} | #{when_str} | #{log_link} |"
    end
end
lines << ""

# --- 2. Top failure categories, this period only ---
lines << "## Top failure categories this period"
lines << ""
if failures_this_period.empty?
  lines << "No failures recorded this period."
else
  by_category = failures_this_period
                .group_by { |r| [r["failure_category"], r["http_status"]] }
                .sort_by { |_, v| -v.size }
  by_category.each do |(category, status), group|
    suffix = status ? " (HTTP #{status})" : ""
    lines << "- #{group.size}x  `#{category}`#{suffix}"
  end
end
lines << ""

# --- 3. Failure rate by repo, this period only ---
lines << "## Failure rate by repo this period"
lines << ""
failures_by_repo_this_period = failures_this_period.group_by { |r| "#{r['org']}/#{r['repo']}" }
repo_slugs_this_period = (failures_by_repo_this_period.keys + totals.keys.select { |s| totals[s][current_period] }).uniq

if repo_slugs_this_period.empty?
  lines << "No data for this period."
else
  repo_stats = repo_slugs_this_period.map do |slug|
    failed = failures_by_repo_this_period.fetch(slug, []).size
    total = totals.dig(slug, current_period) || 0
    rate = total.zero? ? nil : (100.0 * failed / total).round(1)
    [slug, failed, total, rate]
  end
  repo_stats.sort_by { |_, failed, _, _| -failed }.each do |slug, failed, total, rate|
    if total.zero?
      lines << "- **#{slug}**: #{failed} failed (total runs unknown)"
    else
      lines << "- **#{slug}**: #{failed}/#{total} failed (#{rate}%)"
    end
  end
end
lines << ""

# --- 4. Trend across months - kept, but clearly labeled as trend, not "all time" ---
lines << "## Failure rate trend by month"
lines << ""
lines << "_History since this report started collecting - not a full lifetime record._"
lines << ""
failures_by_month = failures.group_by { |r| month_of(r) }
all_known_months = (failures_by_month.keys + total_runs_for_month.keys).reject { |m| m == "unknown" }.uniq
all_known_months.sort.reverse_each do |month|
  failed = failures_by_month.fetch(month, []).size
  total = total_runs_for_month[month]
  if total.zero?
    lines << "- **#{month}**: #{failed} failed (total runs unknown)"
  else
    rate = (100.0 * failed / total).round(1)
    lines << "- **#{month}**: #{failed}/#{total} failed (#{rate}%)"
  end
end

FileUtils.mkdir_p("reports")
File.write("reports/#{current_period}.md", lines.join("\n"))
puts lines.join("\n")
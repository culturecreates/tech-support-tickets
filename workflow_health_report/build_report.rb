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

# Total runs across all repos for a given month.
total_runs_for_month = Hash.new(0)
totals.each_value do |months|
  months.each { |month, count| total_runs_for_month[month] += count }
end

lines = ["# Workflow health report", "", "## Failure rate by month", ""]
failures_by_month = failures.group_by { |r| month_of(r) }
all_months = (failures_by_month.keys + total_runs_for_month.keys).uniq
all_months.sort.reverse_each do |month|
  failed = failures_by_month.fetch(month, []).size
  total = total_runs_for_month[month]
  if total.zero?
    lines << "- **#{month}**: #{failed} failed (total runs unknown)"
  else
    rate = (100.0 * failed / total).round(1)
    lines << "- **#{month}**: #{failed}/#{total} failed (#{rate}%)"
  end
end

lines += ["", "## Failure rate by repo (all time)", ""]
failures_by_repo = failures.group_by { |r| "#{r['org']}/#{r['repo']}" }
repo_slugs = (failures_by_repo.keys + totals.keys).uniq
repo_stats = repo_slugs.map do |slug|
  failed = failures_by_repo.fetch(slug, []).size
  total = (totals[slug] || {}).values.sum
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

lines += ["", "## Top failure categories (all time)", ""]
by_category = failures
              .group_by { |r| [r["failure_category"], r["http_status"]] }
              .sort_by { |_, v| -v.size }

by_category.first(15).each do |(category, status), group|
  suffix = status ? " (HTTP #{status})" : ""
  lines << "- #{group.size}x  `#{category}`#{suffix}"
end

month_tag = Time.now.utc.strftime("%Y-%m")
FileUtils.mkdir_p("reports")
File.write("reports/#{month_tag}.md", lines.join("\n"))
puts lines.join("\n")
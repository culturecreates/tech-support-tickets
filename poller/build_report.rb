# frozen_string_literal: true

require "json"
require "time"

DATA_FILE = "data/workflow_runs.jsonl"
rows = File.readlines(DATA_FILE).map { |l| JSON.parse(l) }

by_month = rows.group_by { |r| r["started_at"] ? r["started_at"][0, 7] : "unknown" }

lines = ["# Workflow health report", "", "## Failure rate by month", ""]
by_month.sort.reverse_each do |month, month_rows|
  failed = month_rows.count { |r| r["result"] == "failure" }
  total = month_rows.size
  rate = total.zero? ? 0 : (100.0 * failed / total).round(1)
  lines << "- **#{month}**: #{failed}/#{total} failed (#{rate}%)"
end

lines += ["", "## Top failure categories (all time)", ""]
by_category = rows.select { |r| r["result"] == "failure" }
                   .group_by { |r| [r["failure_category"], r["http_status"]] }
                   .sort_by { |_, v| -v.size }

by_category.first(15).each do |(category, status), group|
  suffix = status ? " (HTTP #{status})" : ""
  lines << "- #{group.size}x  `#{category}`#{suffix}"
end

month_tag = Time.now.utc.strftime("%Y-%m")
FileUtils.mkdir_p("reports") rescue nil
File.write("reports/#{month_tag}.md", lines.join("\n"))
puts lines.join("\n")
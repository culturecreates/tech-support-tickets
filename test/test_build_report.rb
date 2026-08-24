# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"



SCRIPT = File.expand_path("../workflow_health_report/build_report.rb", __dir__)

SAMPLE_FAILURES = [
  {
    "org" => "culturecreates", "repo" => "artsdata-planet-osac",
    "workflow" => "Fetch Osac Events", "run_id" => 5001, "result" => "failure",
    "started_at" => "2026-08-14T03:00:00Z", "ended_at" => "2026-08-14T03:00:20Z",
    "failure_category" => "databus_error", "http_status" => 403, "ruby_exception_class" => nil
  },
  {
    "org" => "culturecreates", "repo" => "artsdata-planet-agoradanse",
    "workflow" => "Fetch Agoradanse Events", "run_id" => 5002, "result" => "failure",
    "started_at" => "2026-08-12T00:00:00Z", "ended_at" => "2026-08-12T00:00:40Z",
    "failure_category" => "no_pages_loaded", "http_status" => nil, "ruby_exception_class" => nil
  },
  {
    "org" => "artsdata-stewards", "repo" => "artsdata-planet-boost",
    "workflow" => "Process Organization Batch", "run_id" => 5003, "result" => "failure",
    "started_at" => "2026-08-05T04:00:00Z", "ended_at" => "2026-08-05T04:00:50Z",
    "failure_category" => "timeout", "http_status" => nil, "ruby_exception_class" => nil
  },
  {
    "org" => "culturecreates", "repo" => "artsdata-planet-osac",
    "workflow" => "Fetch Osac Events", "run_id" => 4001, "result" => "failure",
    "started_at" => "2026-07-05T03:00:00Z", "ended_at" => "2026-07-05T03:01:00Z",
    "failure_category" => "databus_error", "http_status" => 403, "ruby_exception_class" => nil
  }
].freeze

SAMPLE_TOTALS = {
  "culturecreates/artsdata-planet-osac" => { "2026-07" => 4, "2026-08" => 4 },
  "culturecreates/artsdata-planet-agoradanse" => { "2026-08" => 1 },
  "artsdata-stewards/artsdata-planet-boost" => { "2026-08" => 4 }
}.freeze

class BuildReportTest < Minitest::Test
  # Writes the sample data into a scratch repo layout and runs the real
  # script against it. Returns the generated report text.
  def run_report(failures:, totals:)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "data"))
      File.write(
        File.join(dir, "data", "workflow_runs.jsonl"),
        failures.map(&:to_json).join("\n")
      )
      File.write(File.join(dir, "data", "run_totals.json"), JSON.generate(totals))

      ok = system("ruby", SCRIPT, chdir: dir)
      assert ok, "build_report.rb exited with a nonzero status"

      report_files = Dir.glob(File.join(dir, "reports", "*.md"))
      assert_equal 1, report_files.size, "expected exactly one report file to be written"

      [File.read(report_files.first, encoding: "UTF-8"), File.basename(report_files.first)]
    end
  end

  def test_report_scopes_to_the_most_recent_month_with_data
    report, filename = run_report(failures: SAMPLE_FAILURES, totals: SAMPLE_TOTALS)

    assert_equal "2026-08.md", filename
    assert_includes report, "# Workflow health report — 2026-08"
  end

  def test_failed_workflows_table_lists_only_current_period_sorted_newest_first
    report, = run_report(failures: SAMPLE_FAILURES, totals: SAMPLE_TOTALS)

    table_section = report[/## Failed workflows this period.*?(?=\n## )/m]

    # newest first
    osac_index = table_section.index("artsdata-planet-osac")
    agoradanse_index = table_section.index("artsdata-planet-agoradanse")
    boost_index = table_section.index("artsdata-planet-boost")
    assert osac_index < agoradanse_index
    assert agoradanse_index < boost_index

    # the July failure must NOT appear in the current-period table at all -
    # osac appears in one row only (row start, not the log-link text too)
    assert_equal 1, table_section.scan(/\| culturecreates\/artsdata-planet-osac \|/).size
  end
  
  def test_failure_rate_by_repo_this_period_is_correct
    report, = run_report(failures: SAMPLE_FAILURES, totals: SAMPLE_TOTALS)
    
    assert_includes report, "**culturecreates/artsdata-planet-osac**: 1/4 failed (25.0%)"
    assert_includes report, "**culturecreates/artsdata-planet-agoradanse**: 1/1 failed (100.0%)"
    assert_includes report, "**artsdata-stewards/artsdata-planet-boost**: 1/4 failed (25.0%)"
  end
  
end
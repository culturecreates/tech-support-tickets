# frozen_string_literal: true

require "net/http"
require "json"
require "zip"       # rubyzip gem, to unpack artifact downloads
require "fileutils"
require "time"

ORGS = %w[culturecreates artsdata-stewards].freeze
TOKEN = ENV.fetch("GH_TOKEN")
DATA_FILE = "data/workflow_runs.jsonl"
TOTALS_FILE = "data/run_totals.json" # denominator: total workflow runs per repo per month

def gh_get(path)
  uri = URI("https://api.github.com#{path}")
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Accept"] = "application/vnd.github+json"
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
end

# Paginates through GET endpoints that return {"items": [...]} or a bare array.
def gh_paginate(path, key = nil)
  results = []
  page = 1
  loop do
    res = gh_get("#{path}#{path.include?('?') ? '&' : '?'}per_page=100&page=#{page}")
    break unless res.is_a?(Net::HTTPSuccess)

    body = JSON.parse(res.body)
    batch = key ? body[key] : body
    break if batch.nil? || batch.empty?

    results.concat(batch)
    page += 1
  end
  results
end

def list_repos(org)
  gh_paginate("/orgs/#{org}/repos")
end

# Repo-level artifact listing avoids having to enumerate every run.
def list_result_artifacts(owner, repo, since:)
  gh_paginate("/repos/#{owner}/#{repo}/actions/artifacts", "artifacts")
    .select { |a| a["name"].start_with?("pipeline-result-") }
    .select { |a| Time.parse(a["created_at"]) >= since }
end

# The action names its artifact "pipeline-result-<run_id>-<attempt>", so the
# run_id it covers can be read straight from the name - no download needed
# just to know WHICH runs already have a result.json.
def run_id_from_artifact_name(name)
  name[/pipeline-result-(\d+)/, 1]&.to_i
end

def download_artifact_json(owner, repo, artifact)
  res = gh_get("/repos/#{owner}/#{repo}/actions/artifacts/#{artifact['id']}/zip")
  return nil unless res.is_a?(Net::HTTPRedirection) || res.is_a?(Net::HTTPSuccess)

  zip_url = res["location"] || nil
  zip_data = zip_url ? Net::HTTP.get(URI(zip_url)) : res.body

  Zip::File.open_buffer(zip_data) do |zip|
    entry = zip.glob("result.json").first
    return entry ? JSON.parse(entry.get_input_stream.read) : nil
  end
rescue => e
  warn "Could not read artifact #{artifact['id']} for #{owner}/#{repo}: #{e.message}"
  nil
end

# All workflow runs for a repo in the period. Used for both the totals
# denominator AND for finding failures that pipeline-action never got a
# chance to see (upstream job failed, so its job/artifact step never ran).
def list_runs(owner, repo, since:)
  gh_paginate(
    "/repos/#{owner}/#{repo}/actions/runs?created=%3E#{since.strftime('%Y-%m-%d')}",
    "workflow_runs"
  )
end

def run_totals_by_month(runs)
  runs.each_with_object(Hash.new(0)) do |run, acc|
    stamp = run["run_started_at"] || run["created_at"]
    next unless stamp

    acc[stamp[0, 7]] += 1
  end
end

# For a failed run with no pipeline-action artifact: find which job and
# step actually failed, straight from GitHub's own job listing - no log
# scraping needed, GitHub already knows this.
def failing_job_and_step(owner, repo, run_id)
  jobs = gh_paginate("/repos/#{owner}/#{repo}/actions/runs/#{run_id}/jobs", "jobs")
  failed_job = jobs.find { |j| j["conclusion"] == "failure" }
  return [nil, nil, nil] unless failed_job

  failed_step = (failed_job["steps"] || []).find { |s| s["conclusion"] == "failure" }
  [failed_job["name"], failed_step&.dig("name"), failed_job["id"]]
end

since = (Time.now.utc - 32 * 24 * 60 * 60) # last ~1 month, slight overlap is fine (dedup by run_id)
rows = []
totals = {} # "org/repo" => { "YYYY-MM" => total_runs }

ORGS.each do |org|
  list_repos(org).each do |repo|
    owner = org
    name = repo["name"]
    slug = "#{owner}/#{name}"

    artifacts = list_result_artifacts(owner, name, since: since)
    covered_run_ids = artifacts.map { |a| run_id_from_artifact_name(a["name"]) }.compact

    artifacts.each do |artifact|
      data = download_artifact_json(owner, name, artifact)
      next unless data

      data["org"] = owner
      data["repo"] = name
      rows << data
    end

    runs = list_runs(owner, name, since: since)
    next if runs.empty?

    totals[slug] = run_totals_by_month(runs)

    # Failures pipeline-action never saw: the run failed, but no artifact
    # exists for it because an earlier, unrelated job in the same workflow
    # failed first (git push conflict, a crawl step, a SPARQL query, etc.)
    # and the job that runs pipeline-action never started.
    missed_failures = runs.select { |r| r["conclusion"] == "failure" && !covered_run_ids.include?(r["id"]) }
    missed_failures.each do |run|
      job_name, step_name, job_id = failing_job_and_step(owner, name, run["id"])

      rows << {
        "org" => owner,
        "repo" => name,
        "workflow" => run["name"],
        "run_id" => run["id"],
        "job_id" => job_id,
        "job_name" => job_name,
        "step_name" => step_name,
        "result" => "failure",
        "started_at" => run["run_started_at"] || run["created_at"],
        "ended_at" => run["updated_at"],
        "failure_category" => "failed_outside_pipeline_action",
        "http_status" => nil,
        "ruby_exception_class" => nil
      }
    end
  end
end

FileUtils.mkdir_p("data")
existing_run_ids = File.exist?(DATA_FILE) ? File.readlines(DATA_FILE).map { |l| JSON.parse(l)["run_id"] } : []

File.open(DATA_FILE, "a") do |f|
  rows.each do |row|
    next if row["run_id"] && existing_run_ids.include?(row["run_id"])

    f.puts(row.to_json)
  end
end

# Totals change over time, so merge the freshly computed months into the stored
# snapshot (overwriting the months we just recounted) rather than appending.
stored_totals = File.exist?(TOTALS_FILE) ? JSON.parse(File.read(TOTALS_FILE)) : {}
totals.each do |slug, months|
  stored_totals[slug] ||= {}
  stored_totals[slug].merge!(months)
end
File.write(TOTALS_FILE, JSON.pretty_generate(stored_totals))

puts "Collected #{rows.size} failure rows and totals for #{totals.size} repos this cycle."
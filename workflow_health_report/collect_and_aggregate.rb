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

def gh_get(path, accept: "application/vnd.github+json")
  uri = URI("https://api.github.com#{path}")
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Accept"] = accept
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
end

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

# --- Scope: only workflows that actually have a step using artsdata-pipeline-action ---
# Checking the real file content (not a search index) is deterministic and
# immediate - a workflow added yesterday is seen today, not whenever an
# index catches up. This is the literal, exact definition of "this
# workflow pushes to Artsdata", matching the report's actual goal.
def list_workflow_paths(owner, repo)
  res = gh_get("/repos/#{owner}/#{repo}/contents/.github/workflows")
  return [] unless res.is_a?(Net::HTTPSuccess)

  JSON.parse(res.body)
    .select { |f| f["type"] == "file" && f["name"] =~ /\.ya?ml\z/ }
    .map { |f| f["path"] }
rescue JSON::ParserError
  []
end

def fetch_raw_file(owner, repo, path)
  res = gh_get("/repos/#{owner}/#{repo}/contents/#{path}", accept: "application/vnd.github.raw")
  res.is_a?(Net::HTTPSuccess) ? res.body : nil
end

def uses_pipeline_action?(workflow_yaml_text)
  workflow_yaml_text.match?(/uses:\s*['"]?culturecreates\/artsdata-pipeline-action/)
end

# Maps a workflow file's path to its numeric workflow_id, which the runs API needs.
def workflow_id_for_path(owner, repo, path)
  workflows = gh_paginate("/repos/#{owner}/#{repo}/actions/workflows", "workflows")
  workflows.find { |w| w["path"] == path }&.dig("id")
end

# Runs for one specific workflow only (not the whole repo) - the precise
# scoping this report needs.
def list_workflow_runs(owner, repo, workflow_id, since:)
  gh_paginate(
    "/repos/#{owner}/#{repo}/actions/workflows/#{workflow_id}/runs?created=%3E#{since.strftime('%Y-%m-%d')}",
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

def list_result_artifacts(owner, repo, since:)
  gh_paginate("/repos/#{owner}/#{repo}/actions/artifacts", "artifacts")
    .select { |a| a["name"].start_with?("pipeline-result-") }
    .select { |a| Time.parse(a["created_at"]) >= since }
end

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

# Failures pipeline-action never saw: the run failed, but no artifact exists
# because an earlier, unrelated job in the same workflow failed first (git
# push conflict, a crawl step, a SPARQL query, etc.) and the job that runs
# pipeline-action never started. GitHub's own jobs listing already knows
# exactly which job/step failed - no log scraping needed.
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

    matched_paths = list_workflow_paths(owner, name).select do |path|
      content = fetch_raw_file(owner, name, path)
      content && uses_pipeline_action?(content)
    end
    next if matched_paths.empty? # this repo has nothing to do with pushing to Artsdata

    artifacts = list_result_artifacts(owner, name, since: since)
    covered_run_ids = artifacts.map { |a| run_id_from_artifact_name(a["name"]) }.compact

    artifacts.each do |artifact|
      data = download_artifact_json(owner, name, artifact)
      next unless data

      data["org"] = owner
      data["repo"] = name
      rows << data
    end

    repo_runs = matched_paths.flat_map do |path|
      workflow_id = workflow_id_for_path(owner, name, path)
      workflow_id ? list_workflow_runs(owner, name, workflow_id, since: since) : []
    end
    next if repo_runs.empty?

    totals[slug] = run_totals_by_month(repo_runs)

    missed_failures = repo_runs.select { |r| r["conclusion"] == "failure" && !covered_run_ids.include?(r["id"]) }
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

stored_totals = File.exist?(TOTALS_FILE) ? JSON.parse(File.read(TOTALS_FILE)) : {}
totals.each do |slug, months|
  stored_totals[slug] ||= {}
  stored_totals[slug].merge!(months)
end
File.write(TOTALS_FILE, JSON.pretty_generate(stored_totals))

puts "Collected #{rows.size} failure rows and totals for #{totals.size} in-scope repos this cycle."
# frozen_string_literal: true

require "net/http"
require "json"
require "zip"       # rubyzip gem, to unpack artifact downloads
require "fileutils"
require "time"

ORGS = %w[culturecreates artsdata-stewards].freeze
TOKEN = ENV.fetch("GH_TOKEN")
DATA_FILE = "data/workflow_runs.jsonl"

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

# Cross-check: total run count per repo for the period, so runs whose
# artifact upload itself failed don't just silently vanish from the count.
def total_run_count(owner, repo, since:)
  gh_paginate("/repos/#{owner}/#{repo}/actions/runs?created=%3E#{since.strftime('%Y-%m-%d')}", "workflow_runs").size
end

since = (Time.now.utc - 32 * 24 * 60 * 60) # last ~1 month, slight overlap is fine (dedup by run_id)
rows = []

ORGS.each do |org|
  list_repos(org).each do |repo|
    owner = org
    name = repo["name"]

    artifacts = list_result_artifacts(owner, name, since: since)
    found_run_ids = []

    artifacts.each do |artifact|
      data = download_artifact_json(owner, name, artifact)
      next unless data

      found_run_ids << data["run_id"]
      rows << data
    end

    next if artifacts.empty? # repo doesn't use the shared action - skip the extra API call

    total_runs = total_run_count(owner, name, since: since)
    missing = total_runs - found_run_ids.uniq.size
    next unless missing.positive?

    missing.times do
      rows << {
        "repo" => name, "workflow" => "unknown", "run_id" => nil,
        "result" => "failure", "failure_category" => "artifact_missing",
        "http_status" => nil, "started_at" => nil, "ended_at" => nil
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

puts "Collected #{rows.size} rows this cycle."
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

# Total workflow runs per calendar month for a repo (the report's denominator).
# Artifacts are uploaded on failure only, so this is the *only* source of the
# success side of the ratio. Returns { "YYYY-MM" => count }.
def run_totals_by_month(owner, repo, since:)
  runs = gh_paginate(
    "/repos/#{owner}/#{repo}/actions/runs?created=%3E#{since.strftime('%Y-%m-%d')}",
    "workflow_runs"
  )
  runs.each_with_object(Hash.new(0)) do |run, acc|
    stamp = run["run_started_at"] || run["created_at"]
    next unless stamp

    acc[stamp[0, 7]] += 1
  end
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

since = (Time.now.utc - 32 * 24 * 60 * 60) # last ~1 month, slight overlap is fine (dedup by run_id)
rows = []
totals = {} # "org/repo" => { "YYYY-MM" => total_runs }

ORGS.each do |org|
  list_repos(org).each do |repo|
    owner = org
    name = repo["name"]
    slug = "#{owner}/#{name}"

    artifacts = list_result_artifacts(owner, name, since: since)

    artifacts.each do |artifact|
      data = download_artifact_json(owner, name, artifact)
      next unless data

      # Stamp authoritative org/repo so the report can break down per repo
      # regardless of what the artifact's result.json happens to contain.
      data["org"] = owner
      data["repo"] = name
      rows << data
    end

    next if artifacts.empty? # repo doesn't use the shared action - skip the totals call

    totals[slug] = run_totals_by_month(owner, name, since: since)
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
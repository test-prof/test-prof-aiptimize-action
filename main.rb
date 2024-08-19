# frozen_string_literal: true

require "bundler/inline"

gemfile(true, quiet: true) do
  source "https://rubygems.org"

  gem "octokit"
  gem "base64"
  gem "open3"

  gem "anthropic", "~> 0.2.0"
end

# Core helpers
class CommandResult < Struct.new(:success, :output)
  def success?
    success
  end
end

def log!(msg)
  $stdout.puts(msg)
end

# Fail adds a comment to the issue and exits the script
def fail!(msg)
  log! "[ERROR] #{msg}"
  exit(1)
end

def run_command(cmd)
  log! "Running command: #{cmd}"

  out, err, status = Open3.capture3(cmd)
  CommandResult.new(status.success?, [out, err].reject(&:empty?).join("\n"))
end

# Setup

## Claude
Anthropic.configure do |config|
  config.access_token = ENV.fetch("CLAUDE_API_KEY")
end

CLAUDE_DEFAULTS = {
  model: "claude-3-5-sonnet-20240620",
  max_tokens: 8192,
  temperature: 0.5,
}.freeze

$claude = Anthropic::Client.new

def claude_request(system:, messages:)
  $claude.messages(
    parameters: CLAUDE_DEFAULTS.merge(system: system, messages: messages)
  ).then do |response|
    if response["type"] == "error"
      raise "Error from Claude API: #{response}"
    end

    response["content"].map { _1["text"] }.join("\n")
  end
end

## Prompt
DIFF_EXAMPLE = File.read(ENV.fetch("EXAMPLE_PATCH_PATH"))
PROMPT_TEMPLATE = File.read(ENV.fetch("PROMPT_PATH"))

## GitHub
GITHUB_REPO = ENV.fetch("GITHUB_REPOSITORY")
BASE_BRANCH = ENV.fetch("GITHUB_BASE_BRANCH")

ISSUE_NUMBER = ENV.fetch("GITHUB_ISSUE_NUMBER", "")
TEST_FILE_PATH = ENV.fetch("TEST_FILE_PATH", "")

if ISSUE_NUMBER.empty? && TEST_FILE_PATH.empty?
  fail!("Either issue-number or test-file-path must be provided")
end

## Project
TEST_COMMAND_PREFIX = ENV.fetch("TEST_COMMAND_PREFIX", "bundle exec rspec")

$octokit = Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"))
$pr = nil

# Notify adds a comment to the issue without exiting the script
def notify!(msg)
  log! "[INFO] #{msg}"
  return unless $issue || $pr
  $octokit.add_comment(GITHUB_REPO, $pr&.number || $issue&.number, msg)
end

# Retrieve the task
$issue = nil

if !ISSUE_NUMBER.empty?
  $issue = $octokit.issue(GITHUB_REPO, ISSUE_NUMBER)
end

# First, we try to parse the body and find the path to the file.
# If no match is found, we try to ask Claude for the path.
def file_path_from_issue(txt)
  found = txt.match(/\b(spec\/\S+_spec\.rb)/)&.[](1)
  return found if found

  claude_request(
    system: "You need to extract the file path from the GitHub issue body. Respond with the file path only (no other text), prefixed with 'PATH: <file path'.",
    messages: [{"role": "user", "content": txt}]
  ).then do |response|
    response.match(/PATH: (.+)$/)&.[](1)
  end
end

TARGET_FILE_PATH = TEST_FILE_PATH.empty? ? file_path_from_issue($issue.body) : TEST_FILE_PATH

PR_BRANCH = $issue ? "test-prof/issue-#{$issue.number}" : "test-prof/#{TEST_FILE_PATH.gsub(%r{[^\w/]+}, "-")}"

fail!("Could not find the file path in the issue body") unless TARGET_FILE_PATH

fail!("File does not exist: #{TARGET_FILE_PATH}") unless File.exist?(TARGET_FILE_PATH)

notify!("🤖 I'm on it! Let me first collect some profiles for `#{TARGET_FILE_PATH}`.")

# Try to run RSpec to verify the configuration and obtain the profiling information
result = run_command("FPROF=1 RD_PROF=1 #{TEST_COMMAND_PREFIX} #{TARGET_FILE_PATH}")
unless result.success?
  fail!("Failed to run `rspec #{TARGET_FILE_PATH}`:\n\n```sh\n#{result.output}\n```")
end

PROMPT = PROMPT_TEMPLATE % {example_git_diff: DIFF_EXAMPLE, initial_output: result.output}

log!("PROMPT:\n\n#{PROMPT}\n\n")

notify!("🤖 Okay, here is the baseline information for `#{TARGET_FILE_PATH}`:\n\n```sh\n#{result.output}\n```")

# Main loop

RUNS_LIMIT = 4

def extract_action(lines)
  action_index = lines.find_index { _1 =~ /^Action: (\w+)$/ }

  return unless action_index

  action = Regexp.last_match[1]
  log! "Action: #{action} (at line #{action_index + 1})"

  [action, action_index]
end

def prepare_branch
  client = $octokit
  branch_name = PR_BRANCH
  repo = GITHUB_REPO

  # Delete the branch if it exists
  begin
    client.branch(repo, branch_name)
    client.delete_branch(repo, branch_name)
    log! "Branch #{branch_name} deleted."
  rescue Octokit::NotFound
    log! "Branch #{branch_name} does not exist, so cannot be deleted."
  end


  client.create_ref(repo, "refs/heads/#{branch_name}", client.ref(repo, "heads/#{BASE_BRANCH}").object.sha)
end

def create_pr
  $octokit.create_pull_request(
    GITHUB_REPO, BASE_BRANCH, PR_BRANCH,
    "[TestProf] Optimize: #{TARGET_FILE_PATH}",
    "Closes ##{ISSUE_NUMBER}"
  )
end

def push_code_update(old_code, new_code, path:, message:)
  prepare_branch unless $pr

  $octokit.update_contents(
    GITHUB_REPO, path, message,
    Digest::SHA1.hexdigest("blob #{old_code.bytesize}\0#{old_code}"),
    new_code,
    branch: PR_BRANCH
  )

  return if $pr

  $pr = create_pr
end

run_id = 0
old_code = File.read(TARGET_FILE_PATH)
messages = [{role: "user", content: "Optimize this test file:\n\n #{old_code}"}]
source_file_too_long = false

loop do
  if run_id >= RUNS_LIMIT
    notify!("🤖 Reached the max number of refactoring runs (#{RUNS_LIMIT}). Stopping here.")
    break
  end

  run_id += 1

  log! "BEGIN RUN: #{run_id}"

  response = claude_request(system: PROMPT, messages: messages)

  messages << {role: "assistant", content: response}

  lines = response.split("\n")

  action, action_index = extract_action(lines)

  # No action means we're done
  unless action
    notify!("🤖 We're done here!\n\n#{response}")
    break
  end

  fail!("‼️ Unknown action: #{action}") unless action == "run_rspec"

  code_end_index = lines[action_index..].find_index { _1 =~ /__END__/ }

  unless code_end_index
    log! "No code end found, looks like a partial file..."
    log! "Full answer:\n\n#{response}\n\n"
    return fail!("‼️ Failed to receive an updated test file from LLM") if source_file_too_long

    messages << {role: "user", content: "Observation: This doesn't look like a full Ruby/RSpec file, you must provide a full version"}
    source_file_too_long = true
    next
  end

  source_file_too_long = false

  new_code = lines[action_index + 1..action_index + code_end_index - 1].join("\n") + "\n"
  new_spec_path = TARGET_FILE_PATH.sub(/_spec\.rb$/, "_ai_suggest_#{run_id}_spec.rb")
  File.write(new_spec_path, new_code)

  log! "New spec file saved at #{new_spec_path}"

  push_code_update(old_code, new_code, path: TARGET_FILE_PATH, message: "test-prof: optimize #{TARGET_FILE_PATH} (run #{run_id})")

  old_code = new_code

  # Execute a test for new_spec_path with clean bundle env and capture the output
  output = run_command("FPROF=1 RD_PROF=1 #{TEST_COMMAND_PREFIX} #{new_spec_path}").output

  thought = lines[0...action_index].join("\n")

  notify!("🤖 #{thought}\n\nHere are the results of running an updated version:\n\n```sh\n#{output}\n```")

  messages << {role: "user", content: "Observation:\n\n#{output}"}
rescue => err
  fail!("‼️ Something went wrong: #{err.message}")
end

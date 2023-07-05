# This script is used to run rubocop on the files that have changed in a pull request
# and then comment on the pull request with the offenses found. It also checks the
# pull request for existing comments and removes them if the offense has been fixed.
# This script is intended to run soley in the context of GitHub Actions on pull requests.

# Setup

puts "::group::Installing Rubocop gems"
versioned_rubocop_gems =
  if ENV.fetch("RUBOCOP_GEM_VERSIONS").downcase == "gemfile"
    require "bundler"

    Bundler::LockfileParser.new(Bundler.read_file("Gemfile.lock")).specs
      .select { |spec| spec.name.start_with? "rubocop" }
      .map { |spec| "#{spec.name}:#{spec.version}" }
  else
    ENV.fetch("RUBOCOP_GEM_VERSIONS").split
  end
gem_install_command = "gem install #{versioned_rubocop_gems.join(' ')} --no-document --conservative"
puts "Installing gems with:", gem_install_command
system "time #{gem_install_command}"
puts "::endgroup::"

# Script

require "json"
require "net/http"

module Github
  HttpError = Class.new(StandardError)

  CONNECTION = Net::HTTP.new("api.github.com", 443).tap { |http| http.use_ssl = true }
  REQUEST_METHOD_TO_CLASS = {
    get: Net::HTTP::Get,
    patch: Net::HTTP::Patch,
    post: Net::HTTP::Post,
    delete: Net::HTTP::Delete,
  }.freeze

  REQUEST_METHOD_TO_CLASS.each do |method, klass|
    define_singleton_method(method) do |path, params = nil|
      request(klass, path, params)
    end

    define_singleton_method("#{method}!") do |path, params = nil|
      response = request(klass, path, params)
      raise HttpError, "status: #{response.code}, body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body) if response.body
    end
  end

  def self.request(request_class, path, params = nil)
    request = request_class.new(path)
    request.content_type = "application/json"
    request.body = params&.to_json
    request["Authorization"] = "Bearer #{ENV.fetch('GITHUB_TOKEN')}"
    request["Accept"] = "application/vnd.github.v3+json"

    CONNECTION.request(request)
  end
end

# Figure out which ruby files have changed and run Rubocop on them

github_event = JSON.load_file(ENV.fetch("GITHUB_EVENT_PATH"))
pr_number = github_event.fetch("pull_request").fetch("number")
owner_and_repository = ENV.fetch("GITHUB_REPOSITORY")

changed_files = []
1.step do |page|
  files = Github.get!("/repos/#{owner_and_repository}/pulls/#{pr_number}/files?per_page=100&page=#{page}")
  changed_files.concat(files)
  break if files.length < 100
end
changed_ruby_files = changed_files
  .reject { |file| file.fetch("status") == "removed" }
  .select { |file| file.fetch("filename").end_with?(".rb") }
  .map { |file| file.fetch("filename") }

# JSON reference: https://docs.rubocop.org/rubocop/formatters.html#json-formatter
files_with_offenses =
  if changed_ruby_files.any?
    command = "rubocop #{changed_ruby_files.join(' ')} --format json --force-exclusion"

    puts "Running rubocop with: #{command}"
    rubocop_output = `#{command}`

    JSON.parse(rubocop_output).fetch("files")
  else
    puts "No changed Ruby files, skipping rubocop"

    []
  end

# Fetch existing pull request comments

puts "Fetching comments from https://api.github.com/repos/#{owner_and_repository}/pulls/#{pr_number}/comments"

existing_comments = Github.get!("/repos/#{owner_and_repository}/pulls/#{pr_number}/comments")

comments_made_by_rubocop = existing_comments.select do |comment|
  comment.fetch("body").include?("rubocop-comment-id")
end

# Find existing comments which no longer have offenses and delete them

fixed_comments = comments_made_by_rubocop.reject do |comment|
  files_with_offenses.any? do |file|
    file.fetch("path") == comment.fetch("path") &&
      file.fetch("offenses").any? do |offense|
        offense.fetch("location").fetch("line") == comment.fetch("line")
      end
  end
end

fixed_comments.each do |comment|
  comment_id = comment.fetch("id")
  path = comment.fetch("path")
  line = comment.fetch("line")

  puts "Deleting resolved comment #{comment_id} on #{path} line #{line}"

  Github.delete!("/repos/#{owner_and_repository}/pulls/comments/#{comment_id}")
end

# Comment on the pull request with the offenses found

offences_outside_diff = []

files_with_offenses.each do |file|
  path = file.fetch("path")
  offenses_by_line = file.fetch("offenses").group_by do |offense|
    offense.fetch("location").fetch("line")
  end

  # Group offenses by line number and make a single comment per line
  offenses_by_line.each do |line, offenses|
    puts "Handling #{path} line #{line} with #{offenses.count} offenses"

    message = offenses.map do |offense|
      correctable_prefix = "[Correctable] " if offense.fetch("correctable")
      "#{correctable_prefix}#{offense.fetch('cop_name')}: #{offense.fetch('message')}"
    end.join("\n")

    body = <<~BODY
      <!-- rubocop-comment-id: #{path}-#{line} -->
      #{message}
    BODY

    # If there is already a comment on this line, update it if necessary.
    # Otherwise create a new comment.

    existing_comment = comments_made_by_rubocop.find do |comment|
      comment.fetch("body").include?("rubocop-comment-id: #{path}-#{line}")
    end

    if existing_comment
      comment_id = existing_comment.fetch("id")

      # No need to do anything if the offense already exists and hasn't changed
      if existing_comment.fetch("body") == body
        puts "Skipping unchanged comment #{comment_id} on #{path} line #{line}"
        next
      end

      puts "Updating comment #{comment_id} on #{path} line #{line}"
      Github.patch("/repos/#{owner_and_repository}/pulls/comments/#{comment_id}", body: body)
    else
      puts "Commenting on #{path} line #{line}"

      # Somehow the commit_id should not be just the HEAD SHA: https://stackoverflow.com/a/71431370/1075108
      commit_id = github_event.fetch("pull_request").fetch("head").fetch("sha")

      response = Github.post(
        "/repos/#{owner_and_repository}/pulls/#{pr_number}/comments",
        body: body,
        path: path,
        commit_id: commit_id,
        line: line,
      )

      # Rubocop might hit errors on lines which are not part of the diff and thus cannot be commented on.
      if response.code == "422" && response.body.include?("line must be part of the diff")
        puts "Deferring comment on #{path} line #{line} because it isn't part of the diff"

        offences_outside_diff << { path: path, line: line, message: message }
      end
    end
  end
end

# If there are any offenses outside the diff, make a separate comment for them

if offences_outside_diff.any?
  existing_comment = comments_made_by_rubocop.find do |comment|
    comment.fetch("body").include?("rubocop-comment-id: outside-diff")
  end

  body = <<~BODY
    <!-- rubocop-comment-id: outside-diff -->
    Rubocop offenses found outside of the diff:

  BODY

  body += offences_outside_diff.map do |offense|
    "**#{offense.fetch(:path)}:#{offense.fetch(:line)}**\n#{offense.fetch(:message)}"
  end.join("\n\n")

  if existing_comment
    existing_comment_id = existing_comment.fetch("id")

    # No need to do anything if the offense already exists and hasn't changed
    if existing_comment.fetch("body") == body
      puts "Skipping unchanged separate comment #{existing_comment_id}"
    else
      puts "Updating comment #{existing_comment_id} on pull request"
      Github.patch!("/repos/#{owner_and_repository}/pulls/comments/#{existing_comment_id}", body: body)
    end
  else
    puts "Commenting on pull request with offenses found outside the diff"

    Github.post!("/repos/#{owner_and_repository}/issues/#{pr_number}/comments", body: body)
  end
end

# Fail the build if there were any offenses

number_of_offenses = files_with_offenses.sum { |file| file.fetch("offenses").length }
if number_of_offenses > 0
  puts ""
  puts "#{number_of_offenses} offenses found! Failing the build..."
  exit 108
end

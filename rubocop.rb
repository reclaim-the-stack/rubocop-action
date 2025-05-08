# This script is used to run rubocop on the files that have changed in a pull request
# and then comment on the pull request with the offenses found. It also checks the
# pull request for existing comments and removes them if the offense has been fixed.
# This script is intended to run soley in the context of GitHub Actions on pull requests.

# Setup

require "open3"

puts "::group::Installing Rubocop gems"

if ENV.fetch("RUBOCOP_GEM_VERSIONS").downcase == "gemfile"
  require "bundler"

  gemfile = Bundler::LockfileParser.new(Bundler.read_file("Gemfile.lock"))
  to_remove = gemfile.dependencies.keys.reject do |dependency|
    dependency.include?("rubocop") || dependency == "syntax_tree"
  end

  puts "Removing non rubocop gems from Gemfile"
  system("bundle remove #{to_remove.join(' ')}") or abort("ERROR: Failed to remove non rubocop gems from Gemfile")
  puts

  puts "Resulting Gemfile:"
  puts Bundler.read_file("Gemfile")

  puts "Installing gems with: bundle install"
  system("time bundle install") or abort("ERROR: Failed to install gems")

  rubocop_command = "bundle exec rubocop"
else
  versioned_rubocop_gems = ENV.fetch("RUBOCOP_GEM_VERSIONS").split
  gem_install_command = "gem install #{versioned_rubocop_gems.join(' ')} --no-document --conservative"
  puts "Installing gems with:", gem_install_command
  system "time #{gem_install_command}"

  rubocop_command = "rubocop"
end

puts "::endgroup::"

# Script

require_relative "lib/github"

# Figure out which ruby files have changed and run Rubocop on them

github_event = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
pr_number = github_event.fetch("pull_request").fetch("number")
owner_and_repository = ENV.fetch("GITHUB_REPOSITORY")

changed_ruby_files = Github.pull_request_ruby_files(owner_and_repository, pr_number)

# JSON reference: https://docs.rubocop.org/rubocop/formatters.html#json-formatter
files_with_offenses =
  if changed_ruby_files.any?
    command = "#{rubocop_command} #{changed_ruby_files.map(&:path).join(' ')} --format json --force-exclusion #{ARGV.join(' ')}"

    puts "Running rubocop with: #{command}"
    stdout, stderr, status = Open3.capture3(command)

    if status.success?
      puts "Rubocop finished successfully"
    else
      puts "Rubocop failed with status #{status.exitstatus}"
      puts "Rubocop output:\n#{stdout}" unless stdout.empty?
      puts "Rubocop error output:\n#{stderr}" unless stderr.empty?
    end

    # In case --debug is passed to rubocop, the output is not valid JSON so we have to substring it
    json_start = stdout.index("{")
    json_end = stdout.rindex("}")

    abort "ERROR: No JSON found in rubocop output" unless json_start && json_end

    JSON.parse(stdout[json_start..json_end]).fetch("files")
  else
    puts "No changed Ruby files, skipping rubocop"

    []
  end

# Fetch existing pull request comments

puts "Fetching PR comments from https://api.github.com/repos/#{owner_and_repository}/pulls/#{pr_number}/comments"

existing_comments = Github.get("/repos/#{owner_and_repository}/pulls/#{pr_number}/comments")

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

  Github.delete("/repos/#{owner_and_repository}/pulls/comments/#{comment_id}")
end

# Comment on the pull request with the offenses found

def in_diff?(changed_files, path, line)
  file = changed_files.find { |changed_file| changed_file.path == path }
  file&.changed_lines&.include?(line)
end

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
    elsif in_diff?(changed_ruby_files, path, line)
      puts "Commenting on #{path} line #{line}"

      # Somehow the commit_id should not be just the HEAD SHA: https://stackoverflow.com/a/71431370/1075108
      commit_id = github_event.fetch("pull_request").fetch("head").fetch("sha")

      Github.post(
        "/repos/#{owner_and_repository}/pulls/#{pr_number}/comments",
        body: body,
        path: path,
        commit_id: commit_id,
        line: line,
      )
    else
      offences_outside_diff << { path: path, line: line, message: message }
    end
  end
end

# If there are any offenses outside the diff, make a separate comment for them

separate_comments = Github.get("/repos/#{owner_and_repository}/issues/#{pr_number}/comments")
existing_separate_comment = separate_comments.find do |comment|
  comment.fetch("body").include?("rubocop-comment-id: outside-diff")
end

if offences_outside_diff.any?
  puts "Found #{offences_outside_diff.count} offenses outside of the diff"

  body = <<~BODY
    <!-- rubocop-comment-id: outside-diff -->
    Rubocop offenses found outside of the diff:

  BODY

  body += offences_outside_diff.map do |offense|
    "**#{offense.fetch(:path)}:#{offense.fetch(:line)}**\n#{offense.fetch(:message)}"
  end.join("\n\n")

  if existing_separate_comment
    existing_comment_id = existing_separate_comment.fetch("id")

    # No need to do anything if the offense already exists and hasn't changed
    if existing_separate_comment.fetch("body") == body
      puts "Skipping unchanged separate comment #{existing_comment_id}"
    else
      puts "Updating separate comment #{existing_comment_id}"
      Github.patch("/repos/#{owner_and_repository}/issues/comments/#{existing_comment_id}", body: body)
    end
  else
    puts "Commenting on pull request with offenses found outside the diff"

    Github.post("/repos/#{owner_and_repository}/issues/#{pr_number}/comments", body: body)
  end
elsif existing_separate_comment
  existing_comment_id = existing_separate_comment.fetch("id")
  puts "Deleting resolved separate comment #{existing_comment_id}"
  Github.delete("/repos/#{owner_and_repository}/issues/comments/#{existing_comment_id}")
else
  puts "No offenses found outside of the diff and no existing separate comment to remove"
end

# Fail the build if there were any offenses

number_of_offenses = files_with_offenses.sum { |file| file.fetch("offenses").length }
if number_of_offenses > 0
  puts ""
  puts "#{number_of_offenses} offenses found! Failing the build..."
  exit ENV.fetch("FAILURE_EXIT_CODE", 108).to_i
end

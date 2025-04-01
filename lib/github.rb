require "json"
require "net/http"

module Github
  HttpError = Class.new(StandardError)

  class File
    RANGE_INFORMATION_LINE = /^@@ .+\+(?<line_number>\d+),/.freeze
    MODIFIED_LINE = /^\+(?!\+|\+)/.freeze
    NOT_REMOVED_LINE = /^[^-]/.freeze

    def initialize(file)
      @file = file
    end

    def path
      @file.fetch("filename")
    end

    def changed_lines
      patch = @file.fetch("patch") || ""
      line_number = 0
      patch.each_line.with_object([]) do |line_content, lines|
        case line_content
        when RANGE_INFORMATION_LINE
          line_number = Regexp.last_match[:line_number].to_i
        when MODIFIED_LINE
          lines << line_number
          line_number += 1
        when NOT_REMOVED_LINE
          line_number += 1
        end
      end
    end
  end

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

  def self.pull_request_erb_files(owner_and_repository, pr_number)
    changed_files = []
    1.step do |page|
      files = Github.get!("/repos/#{owner_and_repository}/pulls/#{pr_number}/files?per_page=100&page=#{page}")
      changed_files.concat(files)
      break if files.length < 100
    end
    changed_files
      .reject { |file| file.fetch("status") == "removed" }
      .select { |file| file.fetch("filename").end_with?(".erb") }
      .map { |file| File.new(file) }
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

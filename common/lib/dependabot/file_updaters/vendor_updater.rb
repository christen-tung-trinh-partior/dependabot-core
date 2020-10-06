# frozen_string_literal: true

require "dependabot/dependency_file"

module Dependabot
  module FileUpdaters
    class VendorUpdater
      # notable filenames without a reliable extension:
      TEXT_FILE_NAMES = [
        "README",
        "LICENSE",
        "Gemfile",
        "Gemfile.lock",
        ".bundlecache",
        ".gitignore"
      ].freeze

      TEXT_FILE_EXTS = [
        # code
        ".rb",
        ".erb",
        ".gemspec",
        ".js",
        ".html",
        # config
        ".json",
        ".xml",
        ".toml",
        ".yaml",
        ".yml",
        # docs
        ".md",
        ".txt",
        ".go"
      ].freeze

      def initialize(repo_contents_path:, vendor_dir:)
        @repo_contents_path = repo_contents_path
        @vendor_dir = vendor_dir
      end

      # Returns changed files in the vendor/cache folder
      #
      # @param base_directory [String] Update config base directory
      # @return [Array<Dependabot::DependencyFile>]
      def updated_vendor_cache_files(base_directory:)
        return [] unless repo_contents_path && vendor_dir

        Dir.chdir(repo_contents_path) do
          relative_dir = vendor_dir.sub("#{repo_contents_path}/", "")
          status = SharedHelpers.run_shell_command(
            "git status --untracked-files=all --porcelain=v1 #{relative_dir}"
          )
          changed_paths = status.split("\n").map { |l| l.split(" ") }
          changed_paths.map do |type, path|
            deleted = type == "D"
            encoding = ""
            encoded_content = File.read(path) unless deleted
            if binary_file?(path)
              encoding = Dependabot::DependencyFile::ContentEncoding::BASE64
              encoded_content = Base64.encode64(encoded_content) unless deleted
            end
            Dependabot::DependencyFile.new(
              name: path,
              content: encoded_content,
              directory: base_directory,
              deleted: deleted,
              content_encoding: encoding
            )
          end
        end
      end

      private

      attr_reader :repo_contents_path, :vendor_dir

      def binary_file?(path)
        return false if TEXT_FILE_NAMES.include?(File.basename(path))
        return false if TEXT_FILE_EXTS.include?(File.extname(path))

        true
      end
    end
  end
end

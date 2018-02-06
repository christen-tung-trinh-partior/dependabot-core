# frozen_string_literal: true

require "dependabot/file_fetchers/base"
require "dependabot/file_parsers/java_script/npm_and_yarn"

module Dependabot
  module FileFetchers
    module JavaScript
      class NpmAndYarn < Dependabot::FileFetchers::Base
        def self.required_files_in?(filenames)
          filenames.include?("package.json")
        end

        def self.required_files_message
          "Repo must contain a package.json."
        end

        private

        def fetch_files
          fetched_files = []
          fetched_files << package_json
          fetched_files << package_lock if package_lock
          fetched_files << yarn_lock if yarn_lock
          fetched_files << npmrc if npmrc
          fetched_files += workspace_package_jsons
          fetched_files += path_dependencies
          fetched_files
        end

        def package_json
          @package_json ||= fetch_file_from_host("package.json")
        end

        def package_lock
          @package_lock ||= fetch_file_if_present("package-lock.json")
        end

        def yarn_lock
          @yarn_lock ||= fetch_file_if_present("yarn.lock")
        end

        def npmrc
          @npmrc ||= fetch_file_if_present(".npmrc")
        end

        def path_dependencies
          package_json_files = []
          unfetchable_deps = []

          types = FileParsers::JavaScript::NpmAndYarn::DEPENDENCY_TYPES
          parsed_package_json.values_at(*types).compact.each do |deps|
            deps.map do |name, version|
              next unless version.start_with?("file:")

              path = version.sub(/^file:/, "")
              file = File.join(path, "package.json")

              begin
                package_json_files <<
                  fetch_file_from_host(file, type: "path_dependency")
              rescue Dependabot::DependencyFileNotFound
                unfetchable_deps << name
              end
            end
          end

          if unfetchable_deps.any?
            raise Dependabot::PathDependenciesNotReachable, unfetchable_deps
          end

          package_json_files
        end

        def workspace_package_jsons
          return [] unless parsed_package_json["workspaces"]
          package_json_files = []
          unfetchable_deps = []

          parsed_package_json["workspaces"].each do |path|
            workspaces =
              if path.end_with?("*") then expand_workspaces(path)
              else [path]
              end

            workspaces.each do |workspace|
              file = File.join(workspace, "package.json")

              begin
                package_json_files << fetch_file_from_host(file)
              rescue Dependabot::DependencyFileNotFound
                unfetchable_deps << file
              end
            end
          end

          if unfetchable_deps.any?
            raise Dependabot::PathDependenciesNotReachable, unfetchable_deps
          end

          package_json_files
        end

        def expand_workspaces(path)
          dir = directory.gsub(%r{(^/|/$)}, "")
          repo_contents(dir: path.gsub(/\*$/, "")).
            select { |file| file.type == "dir" }.
            map { |f| f.path.gsub(%r{^/?#{Regexp.escape(dir)}/?}, "") }
        end

        def parsed_package_json
          JSON.parse(package_json.content)
        rescue JSON::ParserError
          raise Dependabot::DependencyFileNotParseable, package_json.path
        end
      end
    end
  end
end

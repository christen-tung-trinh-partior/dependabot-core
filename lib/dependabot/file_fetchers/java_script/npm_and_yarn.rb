# frozen_string_literal: true

require "json"
require "dependabot/file_fetchers/base"
require "dependabot/file_parsers/java_script/npm_and_yarn"

module Dependabot
  module FileFetchers
    module JavaScript
      class NpmAndYarn < Dependabot::FileFetchers::Base
        require_relative "npm_and_yarn/path_dependency_builder"

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
          fetched_files << package_lock if package_lock && !ignore_package_lock?
          fetched_files << yarn_lock if yarn_lock
          fetched_files << shrinkwrap if shrinkwrap
          fetched_files << lerna_json if lerna_json
          fetched_files << npmrc if npmrc
          fetched_files << yarnrc if yarnrc
          fetched_files += workspace_package_jsons
          fetched_files += lerna_packages
          fetched_files += path_dependencies(fetched_files)

          fetched_files.uniq
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

        def shrinkwrap
          @shrinkwrap ||= fetch_file_if_present("npm-shrinkwrap.json")
        end

        def npmrc
          @npmrc ||= fetch_file_if_present(".npmrc")&.
                     tap { |f| f.support_file = true }
        end

        def yarnrc
          @yarnrc ||= fetch_file_if_present(".yarnrc")&.
                      tap { |f| f.support_file = true }
        end

        def lerna_json
          @lerna_json ||= fetch_file_if_present("lerna.json")&.
                          tap { |f| f.support_file = true }
        end

        def workspace_package_jsons
          @workspace_package_jsons ||= fetch_workspace_package_jsons
        end

        def lerna_packages
          @lerna_packages ||= fetch_lerna_packages
        end

        def path_dependencies(fetched_files)
          package_json_files = []
          unfetchable_deps = []

          path_dependency_details(fetched_files).each do |name, path|
            path = path.sub(/^file:/, "")
            filename = File.join(path, "package.json")

            begin
              file = fetch_file_from_host(filename, type: "path_dependency")
              unless fetched_files.map(&:name).include?(file.name)
                package_json_files << file
              end
            rescue Dependabot::DependencyFileNotFound
              unfetchable_deps << [name, path]
            end
          end

          package_json_files += build_unfetchable_deps(unfetchable_deps)

          package_json_files.tap { |fs| fs.each { |f| f.support_file = true } }
        end

        def path_dependency_details(fetched_files)
          package_json_path_deps = []

          fetched_files.each do |file|
            package_json_path_deps +=
              path_dependency_details_from_manifest(file)
          end

          package_lock_path_deps =
            parsed_package_lock.fetch("dependencies", []).to_a.
            select { |_, v| v.fetch("version", "").start_with?("file:") }.
            map { |k, v| [k, v.fetch("version")] }

          shrinkwrap_path_deps =
            parsed_shrinkwrap.fetch("dependencies", []).to_a.
            select { |_, v| v.fetch("version", "").start_with?("file:") }.
            map { |k, v| [k, v.fetch("version")] }

          [
            *package_json_path_deps,
            *package_lock_path_deps,
            *shrinkwrap_path_deps
          ].uniq
        end

        def path_dependency_details_from_manifest(file)
          return [] unless file.name.end_with?("package.json")

          current_dir = file.name.rpartition("/").first
          current_dir = nil if current_dir == ""

          JSON.parse(file.content).
            values_at(*FileParsers::JavaScript::NpmAndYarn::DEPENDENCY_TYPES).
            compact.flat_map(&:to_a).
            select { |_, v| v.start_with?("file:", "/", "./", "../", "~/") }.
            map do |name, path|
              path = path.sub(/^file:/, "")
              path = File.join(current_dir, path) unless current_dir.nil?
              [name, Pathname.new(path).cleanpath.to_path]
            end
        rescue JSON::ParserError
          raise Dependabot::DependencyFileNotParseable, file.path
        end

        def fetch_workspace_package_jsons
          return [] unless parsed_package_json["workspaces"]

          package_json_files = []

          workspace_paths(parsed_package_json["workspaces"]).each do |workspace|
            file = File.join(workspace, "package.json")

            begin
              package_json_files << fetch_file_from_host(file)
            rescue Dependabot::DependencyFileNotFound
              nil
            end
          end

          package_json_files
        end

        def fetch_lerna_packages
          return [] unless parsed_lerna_json["packages"]

          dependency_files = []

          workspace_paths(parsed_lerna_json["packages"]).each do |workspace|
            package_json_path = File.join(workspace, "package.json")
            npm_lock_path = File.join(workspace, "package-lock.json")
            yarn_lock_path = File.join(workspace, "yarn.lock")
            shrinkwrap_path = File.join(workspace, "npm-shrinkwrap.json")

            begin
              dependency_files << fetch_file_from_host(package_json_path)
              dependency_files += [
                fetch_file_if_present(npm_lock_path),
                fetch_file_if_present(yarn_lock_path),
                fetch_file_if_present(shrinkwrap_path)
              ].compact
            rescue Dependabot::DependencyFileNotFound
              nil
            end
          end

          dependency_files
        end

        def workspace_paths(workspace_object)
          paths_array =
            if workspace_object.is_a?(Hash) then workspace_object["packages"]
            elsif workspace_object.is_a?(Array) then workspace_object
            else raise "Unexpected workspace object"
            end

          paths_array.flat_map do |path|
            if path.include?("*") then expanded_paths(path)
            else path
            end
          end
        end

        def expanded_paths(path)
          dir = directory.gsub(%r{(^/|/$)}, "")
          unglobbed_path = path.split("*").first&.gsub(%r{(?<=/)[^/]*$}, "") ||
                           "."

          repo_contents(dir: unglobbed_path, raise_errors: false).
            select { |file| file.type == "dir" }.
            map { |f| f.path.gsub(%r{^/?#{Regexp.escape(dir)}/?}, "") }.
            select { |filename| File.fnmatch?(path, filename) }
        end

        def parsed_package_json
          JSON.parse(package_json.content)
        rescue JSON::ParserError
          raise Dependabot::DependencyFileNotParseable, package_json.path
        end

        def parsed_package_lock
          return {} unless package_lock

          JSON.parse(package_lock.content)
        rescue JSON::ParserError
          {}
        end

        def parsed_shrinkwrap
          return {} unless shrinkwrap

          JSON.parse(shrinkwrap.content)
        rescue JSON::ParserError
          {}
        end

        def ignore_package_lock?
          return false unless npmrc

          npmrc.content.match?(/^package-lock\s*=\s*false/)
        end

        def build_unfetchable_deps(unfetchable_deps)
          return [] unless package_lock || yarn_lock

          unfetchable_deps.map do |name, path|
            PathDependencyBuilder.new(
              dependency_name: name,
              path: path,
              directory: directory,
              package_lock: package_lock,
              yarn_lock: yarn_lock
            ).dependency_file
          end
        end

        def parsed_lerna_json
          return {} unless lerna_json

          JSON.parse(lerna_json.content)
        rescue JSON::ParserError
          raise Dependabot::DependencyFileNotParseable, lerna_json.path
        end
      end
    end
  end
end

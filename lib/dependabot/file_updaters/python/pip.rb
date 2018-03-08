# frozen_string_literal: true

require "toml-rb"

require "python_requirement_parser"
require "dependabot/file_updaters/base"
require "dependabot/shared_helpers"

module Dependabot
  module FileUpdaters
    module Python
      class Pip < Dependabot::FileUpdaters::Base
        def self.updated_files_regex
          [
            /^Pipfile$/,
            /^Pipfile\.lock$/,
            /requirements.*\.txt$/,
            /^constraints\.txt$/,
            /^setup\.py$/
          ]
        end

        def updated_dependency_files
          return updated_pipfile_based_files if pipfile
          updated_requirement_based_files
        end

        private

        def updated_requirement_based_files
          updated_files = []

          changed_requirements =
            dependency.requirements - dependency.previous_requirements

          changed_requirements.each do |req|
            updated_files << updated_file(
              file: original_file(req.fetch(:file)),
              content: updated_requirement_of_setup_file_content(req)
            )
          end

          updated_files
        end

        def updated_pipfile_based_files
          updated_files = []

          if file_changed?(pipfile)
            updated_files <<
              updated_file(file: pipfile, content: updated_pipfile_content)
          end

          if lockfile.content != updated_lockfile_content
            updated_files <<
              updated_file(file: lockfile, content: updated_lockfile_content)
          end

          updated_files
        end

        def dependency
          # For now, we'll only ever be updating a single dependency for Python
          dependencies.first
        end

        def check_required_files
          filenames = dependency_files.map(&:name)
          return if filenames.any? { |name| name.match?(/requirements/x) }
          return if (%w(Pipfile Pipfile.lock) - filenames).empty?
          return if get_original_file("setup.py")
          raise "No requirements.txt or setup.py!"
        end

        def original_file(filename)
          get_original_file(filename)
        end

        def updated_requirement_of_setup_file_content(requirement)
          content = original_file(requirement.fetch(:file)).content

          updated_content =
            content.gsub(
              original_dependency_declaration_string(requirement),
              updated_dependency_declaration_string(requirement)
            )

          raise "Expected content to change!" if content == updated_content
          updated_content
        end

        def original_dependency_declaration_string(requirements)
          regex = PythonRequirementParser::INSTALL_REQ_WITH_REQUIREMENT
          matches = []

          original_file(requirements.fetch(:file)).
            content.scan(regex) { matches << Regexp.last_match }
          dec = matches.find { |match| match[:name] == dependency.name }
          raise "Declaration not found for #{dependency.name}!" unless dec
          dec.to_s
        end

        def updated_dependency_declaration_string(requirement)
          updated_string =
            original_dependency_declaration_string(requirement).sub(
              PythonRequirementParser::REQUIREMENTS,
              requirement.fetch(:requirement)
            )

          return updated_string unless requirement_includes_hashes?(requirement)

          updated_string.sub(
            PythonRequirementParser::HASHES,
            package_hashes_for(
              name: dependency.name,
              version: dependency.version,
              algorithm: hash_algorithm(requirement)
            ).join(hash_separator(requirement))
          )
        end

        def requirement_includes_hashes?(requirement)
          original_dependency_declaration_string(requirement).
            match?(PythonRequirementParser::HASHES)
        end

        def hash_algorithm(requirement)
          return unless requirement_includes_hashes?(requirement)
          original_dependency_declaration_string(requirement).
            match(PythonRequirementParser::HASHES).
            named_captures.fetch("algorithm")
        end

        def hash_separator(requirement)
          return unless requirement_includes_hashes?(requirement)

          hash_regex = PythonRequirementParser::HASH
          original_dependency_declaration_string(requirement).
            match(/#{hash_regex}((?<separator>\s*\\?\s*?)#{hash_regex})*/).
            named_captures.fetch("separator")
        end

        def package_hashes_for(name:, version:, algorithm:)
          SharedHelpers.run_helper_subprocess(
            command: "python3.6 #{python_helper_path}",
            function: "get_dependency_hash",
            args: [name, version, algorithm]
          ).map { |h| "--hash=#{algorithm}:#{h['hash']}" }
        end

        def python_helper_path
          project_root = File.join(File.dirname(__FILE__), "../../../..")
          File.join(project_root, "helpers/python/run.py")
        end

        def updated_pipfile_content
          dependencies.
            select { |dep| requirement_changed?(pipfile, dep) }.
            reduce(pipfile.content.dup) do |content, dep|
              updated_requirement =
                dep.requirements.find { |r| r[:file] == pipfile.name }.
                fetch(:requirement)

              old_req =
                dep.previous_requirements.find { |r| r[:file] == pipfile.name }.
                fetch(:requirement)

              updated_content =
                content.gsub(declaration_regex(dep)) do |line|
                  line.gsub(old_req, updated_requirement)
                end

              raise "Expected content to change!" if content == updated_content
              updated_content
            end
        end

        def updated_lockfile_content
          @updated_lockfile_content ||=
            begin
              pipfile_hash = pipfile_hash_for(updated_pipfile_content)
              updated_lockfile =
                updated_lockfile_content_for(frozen_pipfile_content)

              updated_lockfile.sub(
                /"sha256": ".*?"/,
                %("sha256": "#{pipfile_hash}")
              )
            end
        end

        def frozen_pipfile_content
          frozen_pipfile_json = TomlRB.parse(updated_pipfile_content)

          dependencies.each do |dep|
            name = dep.name
            if frozen_pipfile_json.dig("packages", name)
              frozen_pipfile_json["packages"][name] = "==#{dep.version}"
            end
            if frozen_pipfile_json.dig("dev-packages", name)
              frozen_pipfile_json["dev-packages"][name] = "==#{dep.version}"
            end
          end

          TomlRB.dump(frozen_pipfile_json)
        end

        def updated_lockfile_content_for(pipfile_content)
          SharedHelpers.in_a_temporary_directory do |dir|
            File.write(File.join(dir, "Pipfile.lock"), lockfile.content)
            File.write(File.join(dir, "Pipfile"), pipfile_content)

            SharedHelpers.run_helper_subprocess(
              command: "python #{python_helper_path}",
              function: "update_pipfile",
              args: [dir]
            )
          end.fetch("Pipfile.lock")
        end

        def pipfile_hash_for(pipfile_content)
          SharedHelpers.in_a_temporary_directory do |dir|
            File.write(File.join(dir, "Pipfile"), pipfile_content)
            SharedHelpers.run_helper_subprocess(
              command: "python #{python_helper_path}",
              function: "get_pipfile_hash",
              args: [dir]
            )
          end
        end

        def declaration_regex(dep)
          /(?:^|["'])#{Regexp.escape(dep.name).gsub("-", "[-_.]")}["']?\s*=.*$/i
        end

        def pipfile
          @pipfile ||= get_original_file("Pipfile")
        end

        def lockfile
          @lockfile ||= get_original_file("Pipfile.lock")
        end
      end
    end
  end
end

# frozen_string_literal: true

require "toml-rb"

require "python_requirement_parser"
require "dependabot/file_updaters/base"
require "dependabot/file_parsers/python/pip"
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
          return updated_pipfile_based_files if pipfile && lockfile
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

          if lockfile.content == updated_lockfile_content
            raise "Expected Pipfile.lock to change!"
          end

          updated_files <<
            updated_file(file: lockfile, content: updated_lockfile_content)

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
            command: "pyenv exec python #{python_helper_path}",
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
              original_reqs = parsed_lockfile["_meta"]["requires"]
              original_source = parsed_lockfile["_meta"]["sources"]

              updated_lockfile = updated_lockfile_content_for(prepared_pipfile)
              updated_lockfile_json = JSON.parse(updated_lockfile)
              updated_lockfile_json["_meta"]["hash"]["sha256"] = pipfile_hash
              updated_lockfile_json["_meta"]["requires"] = original_reqs
              updated_lockfile_json["_meta"]["sources"] = original_source

              JSON.pretty_generate(updated_lockfile_json, indent: "    ").
                gsub(/\{\n\s*\}/, "{}").
                gsub(/\}\z/, "}\n")
            end
        end

        def prepared_pipfile
          content = updated_pipfile_content
          content = freeze_other_dependencies(content)
          content = freeze_dependencies_being_updated(content)
          content = add_private_sources(content)
          content
        end

        def freeze_other_dependencies(pipfile_content)
          return pipfile_content unless lockfile
          pipfile_object = TomlRB.parse(pipfile_content)

          FileParsers::Python::Pip::DEPENDENCY_GROUP_KEYS.each do |keys|
            next unless pipfile_object[keys[:pipfile]]

            pipfile_object.fetch(keys[:pipfile]).each do |dep_name, _|
              next if dependencies.map(&:name).include?(dep_name)
              next unless dependency_version(dep_name, keys[:lockfile])

              pipfile_object[keys[:pipfile]][dep_name] =
                "==#{dependency_version(dep_name, keys[:lockfile])}"
            end
          end

          TomlRB.dump(pipfile_object)
        end

        def freeze_dependencies_being_updated(pipfile_content)
          frozen_pipfile_json = TomlRB.parse(pipfile_content)

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

        def add_private_sources(pipfile_content)
          pipfile_object = TomlRB.parse(pipfile_content)

          original_sources = pipfile_object["source"].map(&:dup)
          env_sources = original_sources.select { |h| h["url"].include?("${") }

          updated_sources = original_sources - env_sources + config_sources
          pipfile_object["source"] = updated_sources

          TomlRB.dump(pipfile_object)
        end

        def updated_lockfile_content_for(pipfile_content)
          SharedHelpers.in_a_temporary_directory do
            write_temporary_dependency_files(pipfile_content)
            run_pipenv_command(
              "PIPENV_YES=true pyenv exec pipenv lock --keep-outdated"
            )
            File.read("Pipfile.lock")
          end
        end

        def run_pipenv_command(command)
          raw_response = nil
          IO.popen(command, err: %i(child out)) { |p| raw_response = p.read }

          # Raise an error with the output from the shell session if Pipenv
          # returns a non-zero status
          return if $CHILD_STATUS.success?
          raise SharedHelpers::HelperSubprocessFailed.new(raw_response, command)
        end

        def write_temporary_dependency_files(pipfile_content)
          dependency_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, file.content)
          end

          # Workaround for Pipenv bug
          FileUtils.mkdir_p("python_package.egg-info")

          # Overwrite the pipfile with updated content
          File.write("Pipfile", pipfile_content)
        end

        def pipfile_hash_for(pipfile_content)
          SharedHelpers.in_a_temporary_directory do |dir|
            File.write(File.join(dir, "Pipfile"), pipfile_content)
            SharedHelpers.run_helper_subprocess(
              command:  "pyenv exec python #{python_helper_path}",
              function: "get_pipfile_hash",
              args: [dir]
            )
          end
        end

        def declaration_regex(dep)
          escaped_name = Regexp.escape(dep.name).gsub("\\-", "[-_.]")
          /(?:^|["'])#{escaped_name}["']?\s*=.*$/i
        end

        def dependency_version(dep_name, group)
          parsed_lockfile.dig(group, dep_name, "version")&.gsub(/^==/, "")
        end

        def parsed_lockfile
          @parsed_lockfile ||= JSON.parse(lockfile.content)
        end

        def pipfile
          @pipfile ||= get_original_file("Pipfile")
        end

        def lockfile
          @lockfile ||= get_original_file("Pipfile.lock")
        end

        def config_sources
          @config_sources ||=
            credentials.
            select { |cred| cred["index-url"] }.
            map { |cred| { "url" => cred["index-url"] } }
        end
      end
    end
  end
end

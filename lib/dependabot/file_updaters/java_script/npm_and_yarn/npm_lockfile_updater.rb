# frozen_string_literal: true

require "dependabot/file_updaters/java_script/npm_and_yarn"
require "dependabot/file_parsers/java_script/npm_and_yarn"
require "dependabot/update_checkers/java_script/npm_and_yarn/registry_finder"
require "dependabot/shared_helpers"
require "dependabot/errors"

# rubocop:disable Metrics/ClassLength
module Dependabot
  module FileUpdaters
    module JavaScript
      class NpmAndYarn
        class NpmLockfileUpdater
          require_relative "npmrc_builder"
          require_relative "package_json_updater"

          def initialize(dependencies:, dependency_files:, credentials:)
            @dependencies = dependencies
            @dependency_files = dependency_files
            @credentials = credentials
          end

          def updated_lockfile_content(lockfile)
            path = Pathname.new(lockfile.name).dirname.to_s
            name = Pathname.new(lockfile.name).basename.to_s
            if npmrc_disables_lockfile? ||
               requirements_for_path(dependency.requirements, path).empty?
              return lockfile.content
            end

            @updated_lockfile_content ||= {}
            @updated_lockfile_content[lockfile.name] ||=
              SharedHelpers.in_a_temporary_directory do
                write_temporary_dependency_files(lockfile.name)

                updated_files = Dir.chdir(path) { run_npm_updater(name) }
                updated_content = updated_files.fetch(name)
                updated_content = post_process_npm_lockfile(updated_content)
                raise "No change!" if lockfile.content == updated_content

                updated_content
              end
          rescue SharedHelpers::HelperSubprocessFailed => error
            handle_npm_updater_error(error, lockfile)
          end

          private

          attr_reader :dependencies, :dependency_files, :credentials

          UNREACHABLE_GIT = /ls-remote (?:(-h -t)|(--tags --heads)) (?<url>.*)/
          FORBIDDEN_PACKAGE = /403 Forbidden: (?<package_req>.*)/
          MISSING_PACKAGE = /404 Not Found: (?<package_req>.*)/

          def dependency
            # For now, we'll only ever be updating a single dependency for JS
            dependencies.first
          end

          def requirements_for_path(requirements, path)
            return requirements if path.to_s == "."

            requirements.map do |r|
              next unless r[:file].start_with?("#{path}/")

              r.merge(file: r[:file].gsub(/^#{Regexp.quote("#{path}/")}/, ""))
            end.compact
          end

          def run_npm_updater(lockfile_name)
            SharedHelpers.with_git_configured(credentials: credentials) do
              SharedHelpers.run_helper_subprocess(
                command: "node #{npm_helper_path}",
                function: "update",
                args: [
                  Dir.pwd,
                  dependency.name,
                  dependency.version,
                  dependency.requirements,
                  lockfile_name
                ]
              )
            end
          end

          # rubocop:disable Metrics/AbcSize
          # rubocop:disable Metrics/CyclomaticComplexity
          # rubocop:disable Metrics/PerceivedComplexity
          # rubocop:disable Metrics/MethodLength
          def handle_npm_updater_error(error, lockfile)
            if error.message.match?(MISSING_PACKAGE)
              package_name =
                error.message.match(MISSING_PACKAGE).
                named_captures["package_req"].
                split(/(?<=\w)\@/).first
              handle_missing_package(package_name)
            end
            if error.message.include?("#{dependency.name}@") &&
               error.message.start_with?("No matching vers") &&
               resolvable_before_update?(lockfile)
              # This happens if a new version has been published that relies on
              # but npm is having consistency issues. We raise a bespoke error
              # so we can capture and ignore it if we're trying to create a new
              # PR (which will be created successfully at a later date).
              raise Dependabot::InconsistentRegistryResponse, error.message
            end

            if error.message.start_with?("No matching vers", "404 Not Found") ||
               error.message.include?("not match any file(s) known to git") ||
               error.message.include?("Non-registry package missing package") ||
               error.message.include?("Cannot read property 'match' of ")
              # This happens if a new version has been published that relies on
              # subdependencies that have not yet been published.
              raise if resolvable_before_update?(lockfile)

              msg = "Error while updating #{lockfile.path}:\n"\
                    "#{error.message}"
              raise Dependabot::DependencyFileNotResolvable, msg
            end
            if error.message.include?("fatal: reference is not a tree")
              ref = error.message.match(/a tree: (?<ref>.*)/).
                    named_captures.fetch("ref")
              dep = find_npm_lockfile_dependency_with_ref(ref)
              raise unless dep

              raise Dependabot::GitDependencyReferenceNotFound, dep.fetch(:name)
            end
            if error.message.match?(FORBIDDEN_PACKAGE)
              package_name =
                error.message.match(FORBIDDEN_PACKAGE).
                named_captures["package_req"].
                split(/(?<=\w)\@/).first
              handle_missing_package(package_name)
            end
            if error.message.match?(UNREACHABLE_GIT)
              dependency_url =
                error.message.match(UNREACHABLE_GIT).
                named_captures.fetch("url")
              raise if dependency_url.start_with?("ssh://")

              raise Dependabot::GitDependenciesNotReachable, dependency_url
            end
            raise
          end
          # rubocop:enable Metrics/AbcSize
          # rubocop:enable Metrics/CyclomaticComplexity
          # rubocop:enable Metrics/PerceivedComplexity
          # rubocop:enable Metrics/MethodLength

          def handle_missing_package(package_name)
            missing_dep = FileParsers::JavaScript::NpmAndYarn.new(
              dependency_files: dependency_files,
              source: nil,
              credentials: credentials
            ).parse.find { |dep| dep.name == package_name }

            return unless missing_dep

            reg = UpdateCheckers::JavaScript::NpmAndYarn::RegistryFinder.new(
              dependency: missing_dep,
              credentials: credentials,
              npmrc_file: dependency_files.find { |f| f.name == ".npmrc" }
            ).registry

            if reg == "registry.npmjs.org" && !package_name.start_with?("@")
              return
            end

            raise Dependabot::PrivateSourceAuthenticationFailure, reg
          end

          def resolvable_before_update?(lockfile)
            @resolvable_before_update ||= {}
            if @resolvable_before_update.key?(lockfile.name)
              return @resolvable_before_update[lockfile.name]
            end

            @resolvable_before_update[lockfile.name] =
              begin
                SharedHelpers.in_a_temporary_directory do
                  write_temporary_dependency_files(
                    lockfile.name,
                    update_package_json: false
                  )

                  Dir.chdir(Pathname.new(lockfile.name).dirname) do
                    run_npm_updater(Pathname.new(lockfile.name).basename)
                  end
                end

                true
              rescue SharedHelpers::HelperSubprocessFailed
                false
              end
          end

          def write_temporary_dependency_files(lockfile_name,
                                               update_package_json: true)
            write_lockfiles(lockfile_name)
            File.write(".npmrc", npmrc_content)

            package_files.each do |file|
              path = file.name
              FileUtils.mkdir_p(Pathname.new(path).dirname)

              updated_content =
                if update_package_json
                  updated_package_json_content(file)
                else
                  file.content
                end

              # When updating a package-lock.json we have to manually lock all
              # git dependencies, otherwise npm will (unhelpfully) update them
              updated_content = lock_git_deps(updated_content)
              updated_content = replace_ssh_sources(updated_content)

              updated_content = sanitized_package_json_content(updated_content)
              File.write(file.name, updated_content)
            end
          end

          def write_lockfiles(lockfile_name)
            excluded_lock =
              case lockfile_name
              when "package-lock.json" then "npm-shrinkwrap.json"
              when "npm-shrinkwrap.json" then "package-lock.json"
              end
            [*package_locks, *shrinkwraps].each do |f|
              next if f.name == excluded_lock

              FileUtils.mkdir_p(Pathname.new(f.name).dirname)
              File.write(f.name, f.content)
            end
          end

          def lock_git_deps(content)
            return content if git_dependencies_to_lock.empty?

            types = FileParsers::JavaScript::NpmAndYarn::DEPENDENCY_TYPES

            json = JSON.parse(content)
            types.each do |type|
              json.fetch(type, {}).each do |nm, _|
                updated_version = git_dependencies_to_lock[nm]
                next unless updated_version

                json[type][nm] = git_dependencies_to_lock[nm]
              end
            end

            json.to_json
          end

          def git_dependencies_to_lock
            return {} unless package_locks.any?
            return @git_dependencies_to_lock if @git_dependencies_to_lock

            @git_dependencies_to_lock = {}
            dependency_names = dependencies.map(&:name)

            package_locks.each do |package_lock|
              parsed_lockfile = JSON.parse(package_lock.content)
              parsed_lockfile.fetch("dependencies", {}).each do |nm, details|
                next if dependency_names.include?(nm)
                next unless details["version"]
                next unless details["version"].start_with?("git")

                @git_dependencies_to_lock[nm] = details["version"]
              end
            end
            @git_dependencies_to_lock
          end

          def replace_ssh_sources(content)
            updated_content = content

            git_ssh_requirements_to_swap.each do |req|
              new_req = req.gsub(%r{git\+ssh://git@(.*?)[:/]}, 'https://\1/')
              updated_content = updated_content.gsub(req, new_req)
            end

            updated_content
          end

          def git_ssh_requirements_to_swap
            if @git_ssh_requirements_to_swap
              return @git_ssh_requirements_to_swap
            end

            git_dependencies =
              dependencies.
              select do |dep|
                dep.requirements.any? { |r| r.dig(:source, :type) == "git" }
              end

            @git_ssh_requirements_to_swap = []

            package_files.each do |file|
              FileParsers::JavaScript::NpmAndYarn::DEPENDENCY_TYPES.each do |t|
                JSON.parse(file.content).fetch(t, {}).each do |nm, requirement|
                  next unless git_dependencies.map(&:name).include?(nm)
                  next unless requirement.start_with?("git+ssh:")

                  req = requirement.split("#").first
                  @git_ssh_requirements_to_swap << req
                end
              end
            end

            @git_ssh_requirements_to_swap
          end

          def post_process_npm_lockfile(lockfile_content)
            updated_content = lockfile_content

            git_ssh_requirements_to_swap.each do |req|
              new_r = req.gsub(%r{git\+ssh://git@(.*?)[:/]}, 'git+https://\1/')
              old_r = req.gsub(%r{git@(.*?)[:/]}, 'git@\1/')
              updated_content = updated_content.gsub(new_r, old_r)
            end

            updated_content
          end

          def find_npm_lockfile_dependency_with_ref(ref)
            flatten_dependencies = lambda { |obj|
              deps = []
              obj["dependencies"]&.each do |name, details|
                deps << { name: name, version: details["version"] }
                deps += flatten_dependencies.call(details)
              end
              deps
            }

            deps = package_locks.flat_map do |package_lock|
              flatten_dependencies.call(JSON.parse(package_lock.content))
            end
            deps.find { |dep| dep[:version].end_with?("##{ref}") }
          end

          def npmrc_content
            NpmrcBuilder.new(
              credentials: credentials,
              dependency_files: dependency_files
            ).npmrc_content
          end

          def updated_package_json_content(file)
            @updated_package_json_content ||= {}
            @updated_package_json_content[file.name] ||=
              PackageJsonUpdater.new(
                package_json: file,
                dependencies: dependencies
              ).updated_package_json.content
          end

          def npmrc_disables_lockfile?
            npmrc_content.match?(/^package-lock\s*=\s*false/)
          end

          def sanitized_package_json_content(content)
            content.
              gsub(/\{\{.*?\}\}/, "something"). # {{ name }} syntax not allowed
              gsub(/[^\\]\\ /, " ")             # escaped whitespace not allowed
          end

          def npm_helper_path
            project_root = File.join(File.dirname(__FILE__), "../../../../..")
            File.join(project_root, "helpers/npm/bin/run.js")
          end

          def package_locks
            @package_locks ||=
              dependency_files.
              select { |f| f.name.end_with?("package-lock.json") }
          end

          def shrinkwraps
            @shrinkwraps ||=
              dependency_files.
              select { |f| f.name.end_with?("npm-shrinkwrap.json") }
          end

          def package_files
            dependency_files.select { |f| f.name.end_with?("package.json") }
          end
        end
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength

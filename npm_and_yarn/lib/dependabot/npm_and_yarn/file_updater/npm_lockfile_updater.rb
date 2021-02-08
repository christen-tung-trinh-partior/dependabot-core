# frozen_string_literal: true

require "dependabot/errors"
require "dependabot/logger"
require "dependabot/npm_and_yarn/file_parser"
require "dependabot/npm_and_yarn/file_updater"
require "dependabot/npm_and_yarn/helpers"
require "dependabot/npm_and_yarn/native_helpers"
require "dependabot/npm_and_yarn/update_checker/registry_finder"
require "dependabot/shared_helpers"

# rubocop:disable Metrics/ClassLength
module Dependabot
  module NpmAndYarn
    class FileUpdater
      class NpmLockfileUpdater
        require_relative "npmrc_builder"
        require_relative "package_json_updater"

        def initialize(dependencies:, dependency_files:, credentials:)
          @dependencies = dependencies
          @dependency_files = dependency_files
          @credentials = credentials
        end

        def updated_lockfile_content(lockfile)
          return lockfile.content if npmrc_disables_lockfile?
          return lockfile.content if updatable_dependencies(lockfile).empty?

          @updated_lockfile_content ||= {}
          @updated_lockfile_content[lockfile.name] ||=
            SharedHelpers.in_a_temporary_directory do
              path = Pathname.new(lockfile.name).dirname.to_s
              lockfile_name = Pathname.new(lockfile.name).basename.to_s
              write_temporary_dependency_files(lockfile.name)
              updated_files = Dir.chdir(path) do
                run_current_npm_update(lockfile_name: lockfile_name, lockfile_content: lockfile.content)
              end
              updated_content = updated_files.fetch(lockfile_name)
              post_process_npm_lockfile(lockfile.content, updated_content, lockfile.name)
            end
        rescue SharedHelpers::HelperSubprocessFailed => e
          handle_npm_updater_error(e, lockfile)
        end

        private

        attr_reader :dependencies, :dependency_files, :credentials

        UNREACHABLE_GIT = /fatal: repository '(?<url>.*)' not found/.freeze
        FORBIDDEN_GIT = /fatal: Authentication failed for '(?<url>.*)'/.freeze
        FORBIDDEN_PACKAGE = %r{(?<package_req>[^/]+) - (Forbidden|Unauthorized)}.freeze
        FORBIDDEN_PACKAGE_403 = %r{^403\sForbidden\s
          -\sGET\shttps?://(?<source>[^/]+)/(?<package_req>[^/\s]+)}x.freeze
        MISSING_PACKAGE = %r{(?<package_req>[^/]+) - Not found}.freeze
        INVALID_PACKAGE = /Can't install (?<package_req>.*): Missing/.freeze

        # TODO: look into fixing this in npm, seems like a bug in the git
        # downloader introduced in npm 7
        #
        # NOTE: error message returned from arborist/npm 7 when trying to
        # fetching a invalid/non-existent git ref
        NPM7_MISSING_GIT_REF = /already exists and is not an empty directory/.freeze
        NPM6_MISSING_GIT_REF = /did not match any file\(s\) known to git/.freeze

        def top_level_dependencies
          dependencies.select(&:top_level?)
        end

        def sub_dependencies
          dependencies.reject(&:top_level?)
        end

        def updatable_dependencies(lockfile)
          dependencies.reject do |dependency|
            dependency_up_to_date?(lockfile, dependency) ||
              top_level_dependency_update_not_required?(dependency, lockfile)
          end
        end

        def lockfile_dependencies(lockfile)
          @lockfile_dependencies ||= {}
          @lockfile_dependencies[lockfile.name] ||=
            NpmAndYarn::FileParser.new(
              dependency_files: [lockfile, *package_files],
              source: nil,
              credentials: credentials
            ).parse
        end

        def dependency_up_to_date?(lockfile, dependency)
          existing_dep = lockfile_dependencies(lockfile).
                         find { |dep| dep.name == dependency.name }

          # If the dependency is missing but top level it should be treated as
          # not up to date
          # If it's a missing sub dependency we treat it as up to date
          # (likely it is no longer required)
          return !dependency.top_level? if existing_dep.nil?

          existing_dep&.version == dependency.version
        end

        # NOTE: Prevent changes to npm 6 lockfiles when the dependency has been
        # required in a package.json outside the current folder (e.g. lerna
        # proj). npm 7 introduces workspace support so we explitly want to
        # update the root lockfile and check if the dependency is in the
        # lockfile
        def top_level_dependency_update_not_required?(dependency, lockfile)
          lockfile_dir = Pathname.new(lockfile.name).dirname.to_s

          requirements_for_path = dependency.requirements.select do |req|
            req_dir = Pathname.new(req[:file]).dirname.to_s
            req_dir == lockfile_dir
          end

          dependency_in_lockfile = lockfile_dependencies(lockfile).any? do |dep|
            dep.name == dependency.name
          end

          dependency.top_level? && requirements_for_path.empty? && !dependency_in_lockfile
        end

        def run_current_npm_update(lockfile_name:, lockfile_content:)
          top_level_dependency_updates = top_level_dependencies.map do |d|
            { name: d.name, version: d.version, requirements: d.requirements }
          end

          run_npm_updater(
            lockfile_name: lockfile_name,
            top_level_dependency_updates: top_level_dependency_updates,
            lockfile_content: lockfile_content
          )
        end

        def run_previous_npm_update(lockfile_name:, lockfile_content:)
          previous_top_level_dependencies = top_level_dependencies.map do |d|
            {
              name: d.name,
              version: d.previous_version,
              requirements: d.previous_requirements
            }
          end

          run_npm_updater(
            lockfile_name: lockfile_name,
            top_level_dependency_updates: previous_top_level_dependencies,
            lockfile_content: lockfile_content
          )
        end

        def run_npm_updater(lockfile_name:, top_level_dependency_updates:, lockfile_content:)
          SharedHelpers.with_git_configured(credentials: credentials) do
            if top_level_dependency_updates.any?
              run_npm_top_level_updater(
                lockfile_name: lockfile_name,
                top_level_dependency_updates: top_level_dependency_updates,
                lockfile_content: lockfile_content
              )
            else
              run_npm_subdependency_updater(lockfile_name: lockfile_name, lockfile_content: lockfile_content)
            end
          end
        end

        def run_npm_top_level_updater(lockfile_name:, top_level_dependency_updates:, lockfile_content:)
          if npm7?(lockfile_content)
            run_npm_7_top_level_updater(
              lockfile_name: lockfile_name,
              top_level_dependency_updates: top_level_dependency_updates
            )
          else
            SharedHelpers.run_helper_subprocess(
              command: NativeHelpers.helper_path,
              function: "npm6:update",
              args: [
                Dir.pwd,
                lockfile_name,
                top_level_dependency_updates
              ]
            )
          end
        end

        def run_npm_7_top_level_updater(lockfile_name:, top_level_dependency_updates:)
          # - `--dry-run=false` the updater sets a global .npmrc with dry-run: true to
          #   work around an issue in npm 6, we don't want that here
          # - `--force` ignores checks for platform (os, cpu) and engines
          # - `--ignore-scripts` disables prepare and prepack scripts which are run
          #   when installing git dependencies
          flattenend_manifest_dependencies = flattenend_manifest_dependencies_for_lockfile_name(lockfile_name)
          install_args = npm_top_level_updater_args(
            top_level_dependency_updates: top_level_dependency_updates,
            flattenend_manifest_dependencies: flattenend_manifest_dependencies
          )
          command = [
            "npm",
            "install",
            *install_args,
            "--force",
            "--dry-run",
            "false",
            "--ignore-scripts",
            "--package-lock-only"
          ].join(" ")
          SharedHelpers.run_shell_command(command)
          { lockfile_name => File.read(lockfile_name) }
        end

        def run_npm_subdependency_updater(lockfile_name:, lockfile_content:)
          if npm7?(lockfile_content)
            run_npm_7_subdependency_updater(lockfile_name: lockfile_name)
          else
            SharedHelpers.run_helper_subprocess(
              command: NativeHelpers.helper_path,
              function: "npm6:updateSubdependency",
              args: [Dir.pwd, lockfile_name, sub_dependencies.map(&:to_h)]
            )
          end
        end

        def run_npm_7_subdependency_updater(lockfile_name:)
          dependency_names = sub_dependencies.map(&:name)
          # - `--dry-run=false` the updater sets a global .npmrc with dry-run: true to
          #   work around an issue in npm 6, we don't want that here
          # - `--force` ignores checks for platform (os, cpu) and engines
          # - `--ignore-scripts` disables prepare and prepack scripts which are run
          #   when installing git dependencies
          command = [
            "npm",
            "update",
            *dependency_names,
            "--force",
            "--dry-run",
            "false",
            "--ignore-scripts",
            "--package-lock-only"
          ].join(" ")
          SharedHelpers.run_shell_command(command)
          { lockfile_name => File.read(lockfile_name) }
        end

        # TODO: Update the npm 6 updater to use these args as we currently do
        # the same in the js updater helper, we've kept it seperate for the npm
        # 7 rollout
        def npm_top_level_updater_args(top_level_dependency_updates:, flattenend_manifest_dependencies:)
          top_level_dependency_updates.map do |dependency|
            # NOTE: For git dependencies we loose some information about the
            # requirement that's only available in the package.json, e.g. when
            # specifying a semver tag:
            # `dependabot/depeendabot-core#semver:^0.1` - this is required to
            # pass the correct install argument to `npm install`
            existing_version_requirement = flattenend_manifest_dependencies[dependency.fetch(:name)]
            npm_install_args(
              dependency.fetch(:name),
              dependency.fetch(:version),
              dependency.fetch(:requirements),
              existing_version_requirement
            )
          end
        end

        def flattenend_manifest_dependencies_for_lockfile_name(lockfile_name)
          package_json_content = updated_package_json_content_for_lockfile_name(lockfile_name)
          return {} unless package_json_content

          parsed_package = JSON.parse(package_json_content)
          NpmAndYarn::FileParser::DEPENDENCY_TYPES.inject({}) do |deps, type|
            deps.merge(parsed_package[type] || {})
          end
        end

        def npm_install_args(dep_name, desired_version, requirements, existing_version_requirement)
          git_requirement = requirements.find { |req| req[:source] && req[:source][:type] == "git" }

          if git_requirement
            existing_version_requirement ||= git_requirement[:source][:url]

            # NOTE: Git is configured to auth over https while updating
            existing_version_requirement = existing_version_requirement.gsub(
              %r{git\+ssh://git@(.*?)[:/]}, 'https://\1/'
            )

            # NOTE: Keep any semver range that has already been updated by the
            # PackageJsonUpdater when installing the new version
            if existing_version_requirement.include?(desired_version)
              "#{dep_name}@#{existing_version_requirement}"
            else
              "#{dep_name}@#{existing_version_requirement.sub(/#.*/, '')}##{desired_version}"
            end
          else
            "#{dep_name}@#{desired_version}"
          end
        end

        # rubocop:disable Metrics/AbcSize
        # rubocop:disable Metrics/CyclomaticComplexity
        # rubocop:disable Metrics/PerceivedComplexity
        # rubocop:disable Metrics/MethodLength
        def handle_npm_updater_error(error, lockfile)
          error_message = error.message
          if error_message.match?(MISSING_PACKAGE)
            package_name = error_message.match(MISSING_PACKAGE).
                           named_captures["package_req"]
            sanitized_name = sanitize_package_name(package_name)
            sanitized_error = error_message.gsub(package_name, sanitized_name)
            handle_missing_package(sanitized_name, sanitized_error, lockfile)
          end

          # Invalid package: When the package.json doesn't include a name or
          # version, or name has non url-friendly characters
          # Local path error: When installing a git dependency which
          # is using local file paths for sub-dependencies (e.g. unbuilt yarn
          # workspace project)
          sub_dep_local_path_error = "does not contain a package.json file"
          if error_message.match?(INVALID_PACKAGE) ||
             error_message.include?("Invalid package name") ||
             error_message.include?(sub_dep_local_path_error)
            raise_resolvability_error(error_message, lockfile)
          end

          # TODO: Move this logic to the version resolver and check if a new
          # version and all of its subdependencies are resolvable

          # Make sure the error in question matches the current list of
          # dependencies or matches an existing scoped package, this handles the
          # case where a new version (e.g. @angular-devkit/build-angular) relies
          # on a added dependency which hasn't been published yet under the same
          # scope (e.g. @angular-devkit/build-optimizer)
          #
          # This seems to happen when big monorepo projects publish all of their
          # packages sequentially, which might take enough time for Dependabot
          # to hear about a new version before all of its dependencies have been
          # published
          #
          # OR
          #
          # This happens if a new version has been published but npm is having
          # consistency issues and the version isn't fully available on all
          # queries
          if error_message.include?("No matching vers") &&
             dependencies_in_error_message?(error_message) &&
             resolvable_before_update?(lockfile)

            # Raise a bespoke error so we can capture and ignore it if
            # we're trying to create a new PR (which will be created
            # successfully at a later date)
            raise Dependabot::InconsistentRegistryResponse, error_message
          end

          if error_message.match?(FORBIDDEN_PACKAGE)
            package_name = error_message.match(FORBIDDEN_PACKAGE).
                           named_captures["package_req"]
            sanitized_name = sanitize_package_name(package_name)
            sanitized_error = error_message.gsub(package_name, sanitized_name)
            handle_missing_package(sanitized_name, sanitized_error, lockfile)
          end

          # Some private registries return a 403 when the user is readonly
          if error_message.match?(FORBIDDEN_PACKAGE_403)
            package_name = error_message.match(FORBIDDEN_PACKAGE_403).
                           named_captures["package_req"]
            sanitized_name = sanitize_package_name(package_name)
            sanitized_error = error_message.gsub(package_name, sanitized_name)
            handle_missing_package(sanitized_name, sanitized_error, lockfile)
          end

          if (git_error = error_message.match(UNREACHABLE_GIT) || error_message.match(FORBIDDEN_GIT))
            dependency_url = git_error.named_captures.fetch("url")

            raise Dependabot::GitDependenciesNotReachable, dependency_url
          end

          # This error happens when the lockfile has been messed up and some
          # entries are missing a version, source:
          # https://npm.community/t/cannot-read-property-match-of-undefined/203/3
          #
          # In this case we want to raise a more helpful error message asking
          # people to re-generate their lockfiles (Future feature idea: add a
          # way to click-to-fix the lockfile from the issue)
          if error_message.include?("Cannot read property 'match' of ") &&
             !resolvable_before_update?(lockfile)
            raise_missing_lockfile_version_resolvability_error(error_message,
                                                               lockfile)
          end

          if (error_message.include?("No matching vers") ||
             error_message.include?("404 Not Found") ||
             error_message.include?("Non-registry package missing package") ||
             error_message.include?("Invalid tag name") ||
             error_message.match?(NPM6_MISSING_GIT_REF) ||
             error_message.match?(NPM7_MISSING_GIT_REF)) &&
             !resolvable_before_update?(lockfile)
            raise_resolvability_error(error_message, lockfile)
          end

          # NOTE: This check was introduced in npm7/arborist
          if error_message.include?("must provide string spec")
            msg = "Error parsing your package.json manifest: the version requirement must be a string"
            raise Dependabot::DependencyFileNotParseable, msg
          end

          raise error
        end
        # rubocop:enable Metrics/AbcSize
        # rubocop:enable Metrics/CyclomaticComplexity
        # rubocop:enable Metrics/PerceivedComplexity
        # rubocop:enable Metrics/MethodLength

        def raise_resolvability_error(error_message, lockfile)
          dependency_names = dependencies.map(&:name).join(", ")
          msg = "Error whilst updating #{dependency_names} in "\
                "#{lockfile.path}:\n#{error_message}"
          raise Dependabot::DependencyFileNotResolvable, msg
        end

        def raise_missing_lockfile_version_resolvability_error(error_message,
                                                               lockfile)
          lockfile_dir = Pathname.new(lockfile.name).dirname
          modules_path = lockfile_dir.join("node_modules")
          # NOTE: don't include the dependency names to prevent opening
          # multiple issues for each dependency that fails because we unique
          # issues on the error message (issue detail) on the backend
          #
          # ToDo: add an error ID to issues to make it easier to unique them
          msg = "Error whilst updating dependencies in #{lockfile.name}:\n"\
                "#{error_message}\n\n"\
                "It looks like your lockfile has some corrupt entries with "\
                "missing versions and needs to be re-generated.\n"\
                "You'll need to remove #{lockfile.name} and #{modules_path} "\
                "before you run npm install."
          raise Dependabot::DependencyFileNotResolvable, msg
        end

        def handle_missing_package(package_name, error_message, lockfile)
          missing_dep = lockfile_dependencies(lockfile).
                        find { |dep| dep.name == package_name }

          raise_resolvability_error(error_message, lockfile) unless missing_dep

          reg = NpmAndYarn::UpdateChecker::RegistryFinder.new(
            dependency: missing_dep,
            credentials: credentials,
            npmrc_file: dependency_files.
                        find { |f| f.name.end_with?(".npmrc") },
            yarnrc_file: dependency_files.
                         find { |f| f.name.end_with?(".yarnrc") }
          ).registry

          return if central_registry?(reg) && !package_name.start_with?("@")

          raise Dependabot::PrivateSourceAuthenticationFailure, reg
        end

        def central_registry?(registry)
          NpmAndYarn::FileParser::CENTRAL_REGISTRIES.any? do |r|
            r.include?(registry)
          end
        end

        def resolvable_before_update?(lockfile)
          @resolvable_before_update ||= {}
          return @resolvable_before_update[lockfile.name] if @resolvable_before_update.key?(lockfile.name)

          @resolvable_before_update[lockfile.name] =
            begin
              SharedHelpers.in_a_temporary_directory do
                write_temporary_dependency_files(
                  lockfile.name,
                  update_package_json: false
                )

                lockfile_name = Pathname.new(lockfile.name).basename.to_s
                path = Pathname.new(lockfile.name).dirname.to_s
                Dir.chdir(path) do
                  run_previous_npm_update(lockfile_name: lockfile_name, lockfile_content: lockfile.content)
                end
              end

              true
            rescue SharedHelpers::HelperSubprocessFailed
              false
            end
        end

        def dependencies_in_error_message?(error_message)
          names = dependencies.map { |dep| dep.name.split("/").first }
          # Example format: No matching version found for
          # @dependabot/dummy-pkg-b@^1.3.0
          names.any? do |name|
            error_message.match?(%r{#{Regexp.quote(name)}[\/@]})
          end
        end

        def write_temporary_dependency_files(lockfile_name,
                                             update_package_json: true)
          write_lockfiles(lockfile_name)

          dir = Pathname.new(lockfile_name).dirname
          File.write(File.join(dir, ".npmrc"), npmrc_content)

          package_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)

            updated_content =
              if update_package_json && top_level_dependencies.any?
                updated_package_json_content(file)
              else
                file.content
              end

            # TODO: Figure out if we need to lock git deps for npm 7 and can
            # start deprecating this hornets nest
            #
            # NOTE: When updating a package-lock.json we have to manually lock
            # all git dependencies, otherwise npm will (unhelpfully) update them
            updated_content = lock_git_deps(updated_content)
            updated_content = replace_ssh_sources(updated_content)
            updated_content = lock_deps_with_latest_reqs(updated_content)

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

          json = JSON.parse(content)
          NpmAndYarn::FileParser::DEPENDENCY_TYPES.each do |type|
            json.fetch(type, {}).each do |nm, _|
              updated_version = git_dependencies_to_lock.dig(nm, :version)
              next unless updated_version

              json[type][nm] = git_dependencies_to_lock[nm][:version]
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

              @git_dependencies_to_lock[nm] = {
                version: details["version"],
                from: details["from"]
              }
            end
          end
          @git_dependencies_to_lock
        end

        # When a package.json version requirement is set to `latest`, npm will
        # always try to update these dependencies when doing an `npm install`,
        # regardless of lockfile version. Prevent any unrelated updates by
        # changing the version requirement to `*` while updating the lockfile.
        def lock_deps_with_latest_reqs(content)
          json = JSON.parse(content)

          NpmAndYarn::FileParser::DEPENDENCY_TYPES.each do |type|
            json.fetch(type, {}).each do |nm, requirement|
              next unless requirement == "latest"

              json[type][nm] = "*"
            end
          end

          json.to_json
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
          return @git_ssh_requirements_to_swap if @git_ssh_requirements_to_swap

          @git_ssh_requirements_to_swap = []

          package_files.each do |file|
            NpmAndYarn::FileParser::DEPENDENCY_TYPES.each do |t|
              JSON.parse(file.content).fetch(t, {}).each do |_, requirement|
                next unless requirement.is_a?(String)
                next unless requirement.start_with?("git+ssh:")

                req = requirement.split("#").first
                @git_ssh_requirements_to_swap << req
              end
            end
          end

          @git_ssh_requirements_to_swap
        end

        def post_process_npm_lockfile(original_content, updated_content, lockfile_name)
          updated_content = replace_project_metadata(updated_content, original_content)

          # Switch SSH requirements back for git dependencies
          updated_content = replace_swapped_git_ssh_requirements(updated_content)

          # Switch from details back for git dependencies (they will have
          # changed because we locked them)
          updated_content = replace_locked_git_dependencies(updated_content)

          # Switch back npm 7 lockfile "pacakages" requirements from the package.json
          updated_content = restore_locked_package_dependencies(lockfile_name, updated_content)

          # Switch back the protocol of tarball resolutions if they've changed
          # (fixes an npm bug, which appears to be applied inconsistently)
          replace_tarball_urls(updated_content)
        end

        # NOTE: This is a workaround to "sync" what's in package.json
        # requirements and the `packages.""` entry in npm 7 v2 lockfiles. These
        # get out of sync because we lock git dependencies (that are not being
        # updated) to a specific sha to prevent unrelated updates and the way we
        # invoke the `npm install` cli, where we might tell npm to install a
        # specific versionm e.g. `npm install eslint@1.1.8` but we keep the
        # `package.json` requirement for eslint at `^1.0.0`, in which case we
        # need to copy this from the manifest to the lockfile after the update
        # has finished.
        def restore_locked_package_dependencies(lockfile_name, lockfile_content)
          return lockfile_content unless npm7?(lockfile_content)

          original_package = updated_package_json_content_for_lockfile_name(lockfile_name)
          return lockfile_content unless original_package

          parsed_package = JSON.parse(original_package)
          parsed_lockfile = JSON.parse(lockfile_content)
          dependency_names_to_restore = (dependencies.map(&:name) + git_dependencies_to_lock.keys).uniq

          NpmAndYarn::FileParser::DEPENDENCY_TYPES.each do |type|
            parsed_package.fetch(type, {}).each do |dependency_name, original_requirement|
              next unless dependency_names_to_restore.include?(dependency_name)

              locked_requirement = parsed_lockfile.dig("packages", "", type, dependency_name)
              next unless locked_requirement

              locked_req = %("#{dependency_name}": "#{locked_requirement}")
              original_req = %("#{dependency_name}": "#{original_requirement}")
              lockfile_content = lockfile_content.gsub(locked_req, original_req)
            end
          end

          lockfile_content
        end

        def replace_swapped_git_ssh_requirements(lockfile_content)
          git_ssh_requirements_to_swap.each do |req|
            new_r = req.gsub(%r{git\+ssh://git@(.*?)[:/]}, 'git+https://\1/')
            old_r = req.gsub(%r{git@(.*?)[:/]}, 'git@\1/')
            lockfile_content = lockfile_content.gsub(new_r, old_r)
          end

          lockfile_content
        end

        def replace_locked_git_dependencies(lockfile_content)
          # Switch from details back for git dependencies (they will have
          # changed because we locked them)
          git_dependencies_to_lock.each do |dependency_name, details|
            next unless details[:version] && details[:from]

            # When locking git dependencies in package.json we set the version
            # to be the git commit from the lockfile "version" field which
            # updates the lockfile "from" field to the new git commit when we
            # run npm install
            original_from = %("from": "#{details[:from]}")
            if npm7?(lockfile_content)
              # NOTE: The `from` syntax has changed in npm 7 to inclued the dependency name
              npm7_locked_from = %("from": "#{dependency_name}@#{details[:version]}")
              lockfile_content = lockfile_content.gsub(npm7_locked_from, original_from)
            else
              npm6_locked_from = %("from": "#{details[:version]}")
              lockfile_content = lockfile_content.gsub(npm6_locked_from, original_from)
            end
          end

          lockfile_content
        end

        def replace_tarball_urls(lockfile_content)
          tarball_urls.each do |url|
            trimmed_url = url.gsub(/(\d+\.)*tgz$/, "")
            incorrect_url = if url.start_with?("https")
                              trimmed_url.gsub(/^https:/, "http:")
                            else trimmed_url.gsub(/^http:/, "https:")
                            end
            lockfile_content = lockfile_content.gsub(
              /#{Regexp.quote(incorrect_url)}(?=(\d+\.)*tgz")/,
              trimmed_url
            )
          end

          lockfile_content
        end

        def replace_project_metadata(new_content, old_content)
          old_name = old_content.match(/(?<="name": ").*(?=",)/)&.to_s

          if old_name
            new_content = new_content.
                          sub(/(?<="name": ").*(?=",)/, old_name)
          end

          new_content
        end

        def tarball_urls
          all_urls = [*package_locks, *shrinkwraps].flat_map do |file|
            file.content.scan(/"resolved":\s+"(.*)\"/).flatten
          end
          all_urls.uniq! { |url| url.gsub(/(\d+\.)*tgz$/, "") }

          # If both the http:// and https:// versions of the tarball appear
          # in the lockfile, prefer the https:// one
          trimmed_urls = all_urls.map { |url| url.gsub(/(\d+\.)*tgz$/, "") }
          all_urls.reject do |url|
            next false unless url.start_with?("http:")

            trimmed_url = url.gsub(/(\d+\.)*tgz$/, "")
            trimmed_urls.include?(trimmed_url.gsub(/^http:/, "https:"))
          end
        end

        def npmrc_content
          NpmrcBuilder.new(
            credentials: credentials,
            dependency_files: dependency_files
          ).npmrc_content
        end

        def updated_package_json_content_for_lockfile_name(lockfile_name)
          lockfile_basename = Pathname.new(lockfile_name).basename.to_s
          package_name = lockfile_name.sub(lockfile_basename, "package.json")
          package_json = package_files.find { |f| f.name == package_name }
          return unless package_json

          updated_package_json_content(package_json)
        end

        def updated_package_json_content(file)
          @updated_package_json_content ||= {}
          @updated_package_json_content[file.name] ||=
            PackageJsonUpdater.new(
              package_json: file,
              dependencies: top_level_dependencies
            ).updated_package_json.content
        end

        def npmrc_disables_lockfile?
          npmrc_content.match?(/^package-lock\s*=\s*false/)
        end

        def npm7?(lockfile_content)
          Dependabot::NpmAndYarn::Helpers.npm_version(lockfile_content) == "npm7"
        end

        def sanitized_package_json_content(content)
          content.
            gsub(/\{\{[^\}]*?\}\}/, "something"). # {{ nm }} syntax not allowed
            gsub(/(?<!\\)\\ /, " ").          # escaped whitespace not allowed
            gsub(%r{^\s*//.*}, " ")           # comments are not allowed
        end

        def sanitize_package_name(package_name)
          package_name.gsub("%2f", "/").gsub("%2F", "/")
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
# rubocop:enable Metrics/ClassLength

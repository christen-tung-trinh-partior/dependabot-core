# frozen_string_literal: true

require "dependabot/dependency"
require "dependabot/errors"
require "dependabot/npm_and_yarn/file_parser"
require "dependabot/npm_and_yarn/native_helpers"
require "dependabot/npm_and_yarn/update_checker"
require "dependabot/npm_and_yarn/update_checker/dependency_files_builder"
require "dependabot/shared_helpers"

module Dependabot
  module NpmAndYarn
    class UpdateChecker < Dependabot::UpdateCheckers::Base
      class ConflictingDependencyResolver
        def initialize(dependency_files:, credentials:)
          @dependency_files = dependency_files
          @credentials = credentials
        end

        # Finds any dependencies in the `yarn.lock` or `package-lock.json` that
        # have a subdependency on the given dependency that does not satisfly
        # the target_version.
        #
        # @param dependency [Dependabot::Dependency] the dependency to check
        # @param target_version [String] the version to check
        # @return [Array<Hash{String => String}]
        #   * name [String] the blocking dependencies name
        #   * version [String] the version of the blocking dependency
        #   * requirement [String] the requirement on the target_dependency
        def conflicting_dependencies(dependency:, target_version:)
          SharedHelpers.in_a_temporary_directory do
            dependency_files_builder = DependencyFilesBuilder.new(
              dependency: dependency,
              dependency_files: dependency_files,
              credentials: credentials
            )
            dependency_files_builder.write_temporary_dependency_files

            if dependency_files_builder.yarn_locks.any?
              SharedHelpers.run_helper_subprocess(
                command: NativeHelpers.helper_path,
                function: "yarn:findConflictingDependencies",
                args: [Dir.pwd, dependency.name, target_version.to_s]
              )
            else
              SharedHelpers.run_helper_subprocess(
                command: NativeHelpers.helper_path,
                function: "npm:findConflictingDependencies",
                args: [Dir.pwd, dependency.name, target_version.to_s]
              )
            end
          end
        rescue SharedHelpers::HelperSubprocessFailed
          []
        end

        private

        attr_reader :dependency_files, :credentials
      end
    end
  end
end

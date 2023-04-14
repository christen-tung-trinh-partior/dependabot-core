# frozen_string_literal: true

module Dependabot
  class PullRequestCreator
    class BranchNamer
      class DependencyGroupStrategy
        def initialize(dependencies:, files:, target_branch:, dependency_group:,
                       separator: "/", prefix: "dependabot", max_length: nil)
          @dependencies     = dependencies
          @files            = files
          @target_branch    = target_branch
          @dependency_group = dependency_group
          @separator        = separator
          @prefix           = prefix
          @max_length       = max_length
        end

        def new_branch_name
          File.join(prefixes, dependency_group.name).gsub("/", separator)
        end

        private

        attr_reader :dependencies, :dependency_group, :files, :target_branch, :separator, :prefix, :max_length

        def prefixes
          [
            prefix,
            package_manager,
            directory,
            target_branch
          ].compact
        end

        def package_manager
          dependencies.first.package_manager
        end

        def directory
          files.first.directory.tr(" ", "-")
        end
      end
    end
  end
end

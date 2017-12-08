# frozen_string_literal: true

require "dependabot/metadata_finders"
require "dependabot/pull_request_creator"

module Dependabot
  class PullRequestCreator
    class BranchNamer
      attr_reader :dependencies, :files

      def initialize(dependencies:, files:)
        @dependencies = dependencies
        @files = files
      end

      def new_branch_name
        path = [
          "dependabot",
          dependencies.first.package_manager,
          files.first.directory
        ]
        path = path.compact

        if dependencies.count > 1
          File.join(*path, dependencies.map(&:name).join("-and-"))
        elsif library?
          dep = dependencies.first
          File.join(*path, "#{dep.name}-#{sanitized_requirement(dep)}")
        else
          dep = dependencies.first
          File.join(*path, "#{dep.name}-#{new_version(dep)}")
        end
      end

      private

      def sanitized_requirement(dependency)
        new_library_requirement(dependency).
          delete(" ").
          gsub("!=", "neq-").
          gsub(">=", "gte-").
          gsub("<=", "lte-").
          gsub("~>", "tw-").
          gsub("^", "tw-").
          gsub("||", "or-").
          gsub("~", "approx-").
          gsub("~=", "tw-").
          gsub(/==*/, "eq-").
          gsub(">", "gt-").
          gsub("<", "lt-").
          gsub("*", "star").
          gsub(",", "-and-")
      end

      def new_version(dependency)
        if dependency.version.match?(/^[0-9a-f]{40}$/)
          return new_ref(dependency) if ref_changed?(dependency)
          dependency.version[0..5]
        else
          dependency.version
        end
      end

      def previous_ref(dependency)
        dependency.previous_requirements.map do |r|
          r.dig(:source, "ref") || r.dig(:source, :ref)
        end.compact.first
      end

      def new_ref(dependency)
        dependency.requirements.map do |r|
          r.dig(:source, "ref") || r.dig(:source, :ref)
        end.compact.first
      end

      def ref_changed?(dependency)
        previous_ref(dependency) && new_ref(dependency) &&
          previous_ref(dependency) != new_ref(dependency)
      end

      def new_library_requirement(dependency)
        updated_reqs =
          dependency.requirements - dependency.previous_requirements

        gemspec =
          updated_reqs.find { |r| r[:file].match?(%r{^[^/]*\.gemspec$}) }
        return gemspec[:requirement] if gemspec
        updated_reqs.first[:requirement]
      end

      def library?
        if files.map(&:name).any? { |name| name.match?(%r{^[^/]*\.gemspec$}) }
          return true
        end

        dependencies.none?(&:appears_in_lockfile?)
      end

      def requirements_changed?(dependency)
        (dependency.requirements - dependency.previous_requirements).any?
      end
    end
  end
end

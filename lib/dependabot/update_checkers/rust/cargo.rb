# frozen_string_literal: true

require "excon"
require "dependabot/git_commit_checker"
require "dependabot/update_checkers/base"

module Dependabot
  module UpdateCheckers
    module Rust
      class Cargo < Dependabot::UpdateCheckers::Base
        require_relative "cargo/requirements_updater"
        require_relative "cargo/version_resolver"

        def latest_version
          # TODO: Handle git dependencies
          return if git_dependency?
          return if path_dependency?

          @latest_version =
            begin
              versions = available_versions
              versions.reject!(&:prerelease?) unless wants_prerelease?
              versions.max
            end
        end

        def latest_resolvable_version
          # TODO: Handle git dependencies
          return if git_dependency?
          return if path_dependency?

          @latest_resolvable_version ||=
            VersionResolver.new(
              dependency: dependency,
              dependency_files: dependency_files,
              requirements_to_unlock: :own,
              credentials: credentials
            ).latest_resolvable_version
        end

        def latest_resolvable_version_with_no_unlock
          # TODO: Handle git dependencies
          return if git_dependency?
          return if path_dependency?

          @latest_resolvable_version_with_no_unlock ||=
            VersionResolver.new(
              dependency: dependency,
              dependency_files: dependency_files,
              requirements_to_unlock: :none,
              credentials: credentials
            ).latest_resolvable_version
        end

        def updated_requirements
          RequirementsUpdater.new(
            requirements: dependency.requirements,
            latest_resolvable_version: latest_resolvable_version&.to_s,
            latest_version: latest_version&.to_s,
            library: dependency.version.nil?
          ).updated_requirements
        end

        private

        def latest_version_resolvable_with_full_unlock?
          # Full unlock checks aren't implemented for Rust (yet)
          false
        end

        def updated_dependencies_after_full_unlock
          raise NotImplementedError
        end

        def wants_prerelease?
          if dependency.version &&
             version_class.new(dependency.version).prerelease?
            return true
          end

          dependency.requirements.any? do |req|
            reqs = (req.fetch(:requirement) || "").split(",").map(&:strip)
            reqs.any? { |r| r.match?(/[A-Za-z]/) }
          end
        end

        def available_versions
          crates_listing.
            fetch("versions", []).
            reject { |v| v["yanked"] }.
            map { |v| version_class.new(v.fetch("num")) }
        end

        def git_dependency?
          git_commit_checker.git_dependency?
        end

        def path_dependency?
          sources = dependency.requirements.
                    map { |r| r.fetch(:source) }.uniq.compact

          raise "Multiple sources! #{sources.join(', ')}" if sources.count > 1
          sources.first&.fetch(:type) == "path"
        end

        def git_commit_checker
          @git_commit_checker ||=
            GitCommitChecker.new(
              dependency: dependency,
              github_access_token: github_access_token
            )
        end

        def github_access_token
          credentials.
            find { |cred| cred["host"] == "github.com" }.
            fetch("password")
        end

        def crates_listing
          return @crates_listing unless @crates_listing.nil?

          response = Excon.get(
            "https://crates.io/api/v1/crates/#{dependency.name}",
            idempotent: true,
            middlewares: SharedHelpers.excon_middleware
          )

          @crates_listing = JSON.parse(response.body)
        end
      end
    end
  end
end

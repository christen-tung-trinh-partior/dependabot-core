# frozen_string_literal: true

require "excon"
require "dependabot/update_checkers/java_script/npm_and_yarn"
require "dependabot/update_checkers/java_script/npm_and_yarn/registry_finder"
require "dependabot/utils/java_script/version"
require "dependabot/utils/java_script/requirement"
require "dependabot/shared_helpers"
require "dependabot/errors"

module Dependabot
  module UpdateCheckers
    module JavaScript
      class NpmAndYarn
        class VersionResolver
          def initialize(dependency:, credentials:, dependency_files:)
            @dependency = dependency
            @credentials = credentials
            @dependency_files = dependency_files
          end

          def latest_version_details_from_registry
            return nil unless npm_details&.fetch("dist-tags", nil)

            dist_tag_version = version_from_dist_tags(npm_details)
            return { version: dist_tag_version } if dist_tag_version
            return nil if specified_dist_tag_requirement?

            { version: version_from_versions_array(npm_details) }
          rescue Excon::Error::Socket, Excon::Error::Timeout
            raise if dependency_registry == "registry.npmjs.org"
            # Sometimes custom registries are flaky. We don't want to make that
            # our problem, so we quietly return `nil` here.
          end

          def latest_resolvable_version_with_no_unlock
            reqs = dependency.requirements.map do |r|
              Utils::JavaScript::Requirement.requirements_array(
                r.fetch(:requirement)
              )
            end.compact

            (npm_details || {}).fetch("versions", {}).
              keys.map { |v| version_class.new(v) }.
              reject { |v| v.prerelease? && !wants_prerelease? }.sort.reverse.
              find do |version|
                reqs.all? { |r| r.any? { |opt| opt.satisfied_by?(version) } } &&
                  !yanked?(version)
              end
          rescue Excon::Error::Socket, Excon::Error::Timeout
            raise if dependency_registry == "registry.npmjs.org"
            # Sometimes custom registries are flaky. We don't want to make that
            # our problem, so we quietly return `nil` here.
          end

          private

          attr_reader :dependency, :credentials, :dependency_files

          def version_from_dist_tags(npm_details)
            dist_tags = npm_details["dist-tags"].keys

            # Check if a dist tag was specified as a requirement. If it was, and
            # it exists, use it.
            dist_tag_req =
              dependency.requirements.
              find { |req| dist_tags.include?(req[:requirement]) }&.
              fetch(:requirement)

            if dist_tag_req
              tag_vers =
                version_class.new(npm_details["dist-tags"][dist_tag_req])
              return tag_vers unless yanked?(tag_vers)
            end

            # Use the latest dist tag unless there's a reason not to
            return nil unless npm_details["dist-tags"]["latest"]
            latest = version_class.new(npm_details["dist-tags"]["latest"])

            wants_latest_dist_tag?(latest) ? latest : nil
          end

          def wants_prerelease?
            current_version = dependency.version
            if current_version &&
               version_class.correct?(current_version) &&
               version_class.new(current_version).prerelease?
              return true
            end

            dependency.requirements.any? do |req|
              req[:requirement]&.match?(/\d-[A-Za-z]/)
            end
          end

          def specified_dist_tag_requirement?
            dependency.requirements.any? do |req|
              next false if req[:requirement].nil?
              req[:requirement].match?(/^[A-Za-z]/)
            end
          end

          def wants_latest_dist_tag?(latest_version)
            return false if wants_prerelease?
            return false if latest_version.prerelease?
            return false if current_version_greater_than?(latest_version)
            return false if current_requirement_greater_than?(latest_version)
            return false if yanked?(latest_version)
            true
          end

          def current_version_greater_than?(version)
            return false unless dependency.version
            return false unless version_class.correct?(dependency.version)
            version_class.new(dependency.version) > version
          end

          def current_requirement_greater_than?(version)
            dependency.requirements.any? do |req|
              next false unless req[:requirement]
              req_version = req[:requirement].sub(/^\^|~|>=?/, "")
              next false unless version_class.correct?(req_version)
              version_class.new(req_version) > version
            end
          end

          def version_from_versions_array(npm_details)
            npm_details["versions"].
              keys.map { |v| version_class.new(v) }.
              reject { |v| v.prerelease? && !wants_prerelease? }.sort.reverse.
              find { |version| !yanked?(version) }
          end

          def yanked?(version)
            Excon.get(
              dependency_url + "/#{version}",
              headers: registry_auth_headers,
              idempotent: true,
              middlewares: SharedHelpers.excon_middleware
            ).status == 404
          end

          def npm_details
            @npm_details ||=
              begin
                npm_response = Excon.get(
                  dependency_url,
                  headers: registry_auth_headers,
                  idempotent: true,
                  middlewares: SharedHelpers.excon_middleware
                )

                check_npm_response(npm_response)

                JSON.parse(npm_response.body)
              rescue JSON::ParserError
                @retry_count ||= 0
                @retry_count += 1
                if @retry_count > 2
                  raise if dependency_registry == "registry.npmjs.org"
                  return nil
                end
                sleep(rand(3.0..10.0)) && retry
              end
          end

          def check_npm_response(npm_response)
            if private_dependency_not_reachable?(npm_response)
              raise PrivateSourceNotReachable, dependency_registry
            end

            return if npm_response.status.to_s.start_with?("2")

            # Ignore 404s from the registry for updates where a lockfile doesn't
            # need to be generated. The 404 won't cause problems later.
            return if npm_response.status == 404 && dependency.version.nil?

            return if npm_response.status == 404 && git_dependency?
            raise "Got #{npm_response.status} response with body "\
                  "#{npm_response.body}"
          end

          def private_dependency_not_reachable?(npm_response)
            # Check whether this dependency is (likely to be) private
            if dependency_registry == "registry.npmjs.org" &&
               !dependency.name.start_with?("@")
              return false
            end

            [401, 403, 404].include?(npm_response.status)
          end

          def dependency_url
            registry_finder.dependency_url
          end

          def dependency_registry
            registry_finder.registry
          end

          def registry_auth_headers
            registry_finder.auth_headers
          end

          def registry_finder
            @registry_finder ||=
              NpmAndYarn::RegistryFinder.new(
                dependency: dependency,
                credentials: credentials,
                npmrc_file: dependency_files.find { |f| f.name == ".npmrc" }
              )
          end

          def version_class
            Utils::JavaScript::Version
          end

          # TODO: Remove need for me
          def git_dependency?
            GitCommitChecker.new(
              dependency: dependency,
              github_access_token: github_access_token
            ).git_dependency?
          end

          def github_access_token
            credentials.
              find { |cred| cred["host"] == "github.com" }.
              fetch("password")
          end
        end
      end
    end
  end
end

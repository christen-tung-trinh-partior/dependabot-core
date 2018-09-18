# frozen_string_literal: true

require "dependabot/dependency"
require "dependabot/file_parsers/base/dependency_set"
require "dependabot/file_parsers/go/dep"
require "dependabot/utils/go/path_converter"
require "dependabot/errors"

module Dependabot
  module FileParsers
    module Go
      module Modules
        class GoModParser
          GIT_VERSION_REGEX = /^v0\.0\.0-\d{14}-(?<sha>[0-9a-f]{12})$/

          def initialize(dependency_files:, credentials:)
            @dependency_files = dependency_files
            @credentials = credentials
          end

          def dependency_set
            dependency_set = Dependabot::FileParsers::Base::DependencySet.new
            dependency_set += go_mod_dependencies
            dependency_set
          end

          private

          attr_reader :dependency_files, :credentials

          def go_mod_dependencies
            dependencies = Dependabot::FileParsers::Base::DependencySet.new

            i = 0
            chunks = module_info(go_mod).lines.
                     group_by { |line| line == "{\n" ? i += 1 : i }
            deps = chunks.values.map { |chunk| JSON.parse(chunk.join) }

            deps.each do |dep|
              # The project itself appears in this list as "Main"
              next if dep["Main"]

              dependency = dependency_from_details(dep)
              dependencies << dependency if dependency
            end

            dependencies
          end

          def dependency_from_details(details)
            source =
              if rev_identifier?(details) then git_source(details)
              else { type: "default", source: details["Path"] }
              end

            version =
              if rev_identifier?(details) then git_revision(details)
              else details["Version"]&.sub(/^v?/, "")
              end

            reqs = [{
              requirement: rev_identifier?(details) ? nil : details["Version"],
              file: go_mod.name,
              source: source,
              groups: []
            }]

            Dependency.new(
              name: details["Path"],
              version: version,
              requirements: details["Indirect"] ? [] : reqs,
              package_manager: "dep"
            )
          end

          def module_info(go_mod)
            @module_info ||=
              SharedHelpers.in_a_temporary_directory do
                SharedHelpers.with_git_configured(credentials: credentials) do
                  File.write("go.mod", go_mod.content)

                  output = `GO111MODULE=on go list -m -json all`
                  unless $CHILD_STATUS.success?
                    raise Dependabot::DependencyFileNotParseable, go_mod.path
                  end

                  output
                end
              end
          end

          def rev_identifier?(dep)
            dep["Version"]&.match?(GIT_VERSION_REGEX)
          end

          def git_source(dep)
            url = Utils::Go::PathConverter.git_source_for_path(dep["Path"])&.url

            # Currently, we have no way of knowing whether the commit tagged
            # is being used because a branch is being followed or because a
            # particular ref is in use. (The go.mod gives no information.)
            {
              type: "git",
              url: url || dep["Path"]
            }
          end

          def git_revision(dep)
            raw_version = dep.fetch("Version")
            return raw_version unless raw_version.match?(GIT_VERSION_REGEX)

            raw_version.match(GIT_VERSION_REGEX).named_captures.fetch("sha")
          end

          def go_mod
            @go_mod ||= dependency_files.find { |f| f.name == "go.mod" }
          end
        end
      end
    end
  end
end

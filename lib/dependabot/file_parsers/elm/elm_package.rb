# frozen_string_literal: true

require "dependabot/dependency"
require "dependabot/file_parsers/base"
require "dependabot/file_fetchers/elm/elm_package"
require "dependabot/shared_helpers"
require "dependabot/utils/elm/version"
require "dependabot/utils/elm/requirement"

module Dependabot
  module FileParsers
    module Elm
      class ElmPackage < Dependabot::FileParsers::Base
        require "dependabot/file_parsers/base/dependency_set"

        DEPENDENCY_TYPES = %w(dependencies test-dependencies).freeze

        def parse
          dependency_set = DependencySet.new

          dependency_set += elm_package_dependencies if elm_package_file
          dependency_set += elm_json_dependencies if elm_json

          dependency_set.dependencies.sort_by(&:name)
        end

        private

        def elm_package_dependencies
          dependency_set = DependencySet.new

          parsed_package_file.fetch("dependencies").each do |name, req|
            dependency_set <<
              Dependency.new(
                name: name,
                version: version_for(req)&.to_s,
                requirements: [{
                  requirement: req, # 4.0 <= v <= 4.0
                  groups: [], # we don't have this (its dev vs non-dev)
                  source: nil, # elm-package only has elm-package sources
                  file: "elm-package.json"
                }],
                package_manager: "elm-package"
              )
          end

          dependency_set
        end

        # For docs on elm.json, see:
        # https://github.com/elm/compiler/blob/master/docs/elm.json/application.md
        # https://github.com/elm/compiler/blob/master/docs/elm.json/package.md
        def elm_json_dependencies
          dependency_set = DependencySet.new

          # TODO: Do some parsing!

          dependency_set
        end

        def check_required_files
          raise "No elm-package.json!" unless elm_package_file
        end

        def version_for(version_requirement)
          req = Dependabot::Utils::Elm::Requirement.new(version_requirement)

          return unless req.exact?
          req.requirements.first.last
        end

        def parsed_package_file
          @parsed_package_file ||= JSON.parse(elm_package_file.content)
        end

        def elm_package_file
          @elm_package_file ||= get_original_file("elm-package.json")
        end

        def elm_json
          @elm_json ||= get_original_file("elm.json")
        end

        def parsed_elm_json
          @parsed_elm_json ||= JSON.parse(elm_json.content)
        end
      end
    end
  end
end

# frozen_string_literal: true

require "toml-rb"

require "dependabot/dependency"
require "dependabot/file_parsers/base"

module Dependabot
  module FileParsers
    module Python
      class Pipfile < Dependabot::FileParsers::Base
        def parse
          runtime_dependencies + development_dependencies
        end

        private

        def check_required_files
          %w(Pipfile Pipfile.lock).each do |filename|
            raise "No #{filename}!" unless get_original_file(filename)
          end
        end

        def runtime_dependencies
          parsed_pipfile.fetch("packages", {}).map do |dep_name, req|
            next unless req.is_a?(String)
            version =
              parsed_lockfile.dig("default", dep_name.downcase, "version")
            Dependency.new(
              name: dep_name,
              version: version.gsub(/^==/, ""),
              requirements: [
                {
                  requirement: req,
                  file: pipfile.name,
                  source: nil,
                  groups: ["default"]
                }
              ],
              package_manager: "pipfile"
            )
          end.compact
        end

        def development_dependencies
          parsed_pipfile.fetch("dev-packages", {}).map do |dep_name, req|
            next unless req.is_a?(String)
            version =
              parsed_lockfile.dig("develop", dep_name.downcase, "version")
            Dependency.new(
              name: dep_name,
              version: version.gsub(/^==/, ""),
              requirements: [
                {
                  requirement: req,
                  file: pipfile.name,
                  source: nil,
                  groups: ["develop"]
                }
              ],
              package_manager: "pipfile"
            )
          end.compact
        end

        def parsed_pipfile
          TomlRB.parse(pipfile.content)
        end

        def parsed_lockfile
          JSON.parse(lockfile.content)
        end

        def pipfile
          @pipfile ||= get_original_file("Pipfile")
        end

        def lockfile
          @lockfile ||= get_original_file("Pipfile.lock")
        end
      end
    end
  end
end

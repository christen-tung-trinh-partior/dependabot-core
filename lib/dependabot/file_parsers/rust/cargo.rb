# frozen_string_literal: true

require "toml-rb"

require "dependabot/dependency"
require "dependabot/file_parsers/base"
require "dependabot/update_checkers/rust/cargo/requirement"
require "dependabot/update_checkers/rust/cargo/version"
require "dependabot/errors"

# Relevant Cargo docs can be found at:
# - https://doc.rust-lang.org/cargo/reference/manifest.html
# - https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html
module Dependabot
  module FileParsers
    module Rust
      class Cargo < Dependabot::FileParsers::Base
        require "dependabot/file_parsers/base/dependency_set"

        DEPENDENCY_TYPES =
          %w(dependencies dev-dependencies build-dependencies).freeze

        def parse
          dependency_set = DependencySet.new
          dependency_set += manifest_dependencies
          dependency_set += lockfile_dependencies if lockfile
          dependency_set.dependencies
        end

        private

        def manifest_dependencies
          dependency_set = DependencySet.new

          DEPENDENCY_TYPES.each do |type|
            manifest_files.each do |file|
              parsed_file(file).fetch(type, {}).each do |name, requirement|
                dependency_set << Dependency.new(
                  name: name,
                  version: version_from_lockfile(name, requirement),
                  package_manager: "cargo",
                  requirements: [{
                    requirement: requirement_from_declaration(requirement),
                    file: file.name,
                    groups: [type],
                    source: source_from_declaration(requirement)
                  }]
                )
              end
            end
          end

          dependency_set
        end

        def lockfile_dependencies
          dependency_set = DependencySet.new
          return dependency_set unless lockfile

          parsed_file(lockfile).fetch("package", []).each do |package_details|
            next unless package_details["source"]

            # TODO: This isn't quite right, as it will only give us one
            # version of each dependency (when in fact there are many)
            dependency_set << Dependency.new(
              name: package_details["name"],
              version: version_from_lockfile_details(package_details),
              package_manager: "cargo",
              requirements: []
            )
          end

          dependency_set
        end

        def requirement_from_declaration(declaration)
          return declaration if declaration.is_a?(String)
          unless declaration.is_a?(Hash)
            raise "Unexpected dependency declaration: #{declaration}"
          end
          return declaration["version"] if declaration["version"]
          nil
        end

        def source_from_declaration(declaration)
          return if declaration.is_a?(String)
          unless declaration.is_a?(Hash)
            raise "Unexpected dependency declaration: #{declaration}"
          end

          return git_source_details(declaration) if declaration["git"]
          return { type: "path" } if declaration["path"]

          return if declaration["version"]
          raise "Unexpected dependency declaration: #{declaration}"
        end

        def version_from_lockfile(name, declaration)
          return unless lockfile

          candidate_packages =
            parsed_file(lockfile).fetch("package", []).
            select { |p| p["name"] == name }

          if (req = requirement_from_declaration(declaration))
            req = UpdateCheckers::Rust::Cargo::Requirement.new(req)

            candidate_packages =
              candidate_packages.
              select { |p| req.satisfied_by?(version_class.new(p["version"])) }
          end

          package =
            candidate_packages.
            max_by { |p| version_class.new(p["version"]) }

          version_from_lockfile_details(package)
        end

        def git_source_details(declaration)
          {
            type: "git",
            url: declaration["git"],
            branch: declaration["branch"],
            ref: declaration["tag"] || declaration["rev"]
          }
        end

        def version_from_lockfile_details(package_details)
          unless package_details["source"]&.start_with?("git+")
            return package_details["version"]
          end
          package_details["source"].split("#").last
        end

        def check_required_files
          raise "No Cargo.toml!" unless get_original_file("Cargo.toml")
        end

        def parsed_file(file)
          @parsed_file ||= {}
          @parsed_file[file.name] ||= TomlRB.parse(file.content)
        rescue TomlRB::ParseError
          raise Dependabot::DependencyFileNotParseable, file.path
        end

        def manifest_files
          @manifest_files ||=
            dependency_files.select { |f| f.name.end_with?("Cargo.toml") }
        end

        def lockfile
          @lockfile ||= get_original_file("Cargo.lock")
        end

        def version_class
          UpdateCheckers::Rust::Cargo::Version
        end
      end
    end
  end
end

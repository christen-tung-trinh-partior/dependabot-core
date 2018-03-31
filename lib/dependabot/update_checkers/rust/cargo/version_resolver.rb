# frozen_string_literal: true

require "toml-rb"
require "dependabot/shared_helpers"
require "dependabot/file_parsers/rust/cargo"
require "dependabot/update_checkers/rust/cargo"

module Dependabot
  module UpdateCheckers
    module Rust
      class Cargo
        class VersionResolver
          def initialize(dependency:, dependency_files:,
                         requirements_to_unlock:)
            @dependency = dependency
            @dependency_files = dependency_files
            @requirements_to_unlock = requirements_to_unlock
          end

          def latest_resolvable_version
            @latest_resolvable_version ||= fetch_latest_resolvable_version
          end

          private

          attr_reader :dependency, :dependency_files, :requirements_to_unlock

          def fetch_latest_resolvable_version
            SharedHelpers.in_a_temporary_directory do
              write_temporary_dependency_files

              # Shell out to Cargo, which handles everything for us, and does
              # so without doing an install (so it's fast).
              command = "cargo update -p #{dependency_spec}"
              run_cargo_command(command)

              updated_version = TomlRB.
                                parse(File.read("Cargo.lock")).
                                fetch("package").
                                find { |p| p["name"] == dependency.name }.
                                fetch("version")

              return updated_version if updated_version.nil?
              Gem::Version.new(updated_version)
            end
          end

          def dependency_spec
            spec = dependency.name
            if dependency.previous_version
              spec += ":#{dependency.previous_version}"
            end
            spec
          end

          def run_cargo_command(command)
            raw_response = nil
            IO.popen(command, err: %i(child out)) do |process|
              raw_response = process.read
            end

            # Raise an error with the output from the shell session if Cargo
            # returns a non-zero status
            return if $CHILD_STATUS.success?
            raise SharedHelpers::HelperSubprocessFailed.new(
              raw_response,
              command
            )
          end

          def write_temporary_dependency_files
            manifest_files.each do |file|
              path = file.name
              dir = Pathname.new(path).dirname
              FileUtils.mkdir_p(Pathname.new(path).dirname)
              File.write(file.name, updated_manifest_file_content(file))

              FileUtils.mkdir_p(File.join(dir, "src"))
              File.write(File.join(dir, "src/lib.rs"), dummy_app_content)
              File.write(File.join(dir, "src/main.rs"), dummy_app_content)
            end

            File.write(lockfile.name, lockfile.content) if lockfile
          end

          # Note: We don't need to care about formatting in this method, since
          # we're only using the manifest to find the latest resolvable version
          def updated_manifest_file_content(file)
            return file.content if requirements_to_unlock == :none
            parsed_manifest = TomlRB.parse(file.content)

            FileParsers::Rust::Cargo::DEPENDENCY_TYPES.each do |type|
              next unless (req = parsed_manifest.dig(type, dependency.name))
              updated_req =
                if dependency.version then ">= #{dependency.version}"
                else ">= 0"
                end

              if req.is_a?(Hash)
                parsed_manifest[type][dependency.name]["version"] = updated_req
              else
                parsed_manifest[type][dependency.name] = updated_req
              end
            end

            TomlRB.dump(parsed_manifest)
          end

          def dummy_app_content
            %{fn main() {\nprintln!("Hello, world!");\n}}
          end

          def manifest_files
            @manifest_files ||=
              dependency_files.select { |f| f.name.end_with?("Cargo.toml") }
          end

          def lockfile
            @lockfile ||= dependency_files.find { |f| f.name == "Cargo.lock" }
          end
        end
      end
    end
  end
end

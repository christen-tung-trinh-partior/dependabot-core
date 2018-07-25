# frozen_string_literal: true

require "toml-rb"

require "dependabot/shared_helpers"
require "dependabot/dependency_file"
require "dependabot/file_updaters/go/dep"
require "dependabot/file_parsers/go/dep"

module Dependabot
  module FileUpdaters
    module Go
      class Dep
        class LockfileUpdater
          def initialize(dependencies:, dependency_files:, credentials:)
            @dependencies = dependencies
            @dependency_files = dependency_files
            @credentials = credentials
          end

          def updated_lockfile_content
            updated_content =
              Dir.chdir(go_dir) do
                write_temporary_dependency_files

                SharedHelpers.with_git_configured(credentials: credentials) do
                  # Shell out to dep, which handles everything for us, and does
                  # so without doing an install (so it's fast).
                  command = "dep ensure -update --no-vendor "\
                            "#{dependencies.map(&:name).join(' ')}"
                  run_shell_command(command)
                end

                File.read("Gopkg.lock")
              end

            FileUtils.rm_rf(go_dir)
            updated_content
          end

          private

          attr_reader :dependencies, :dependency_files, :credentials

          def run_shell_command(command)
            raw_response = nil
            IO.popen(command, err: %i(child out)) do |process|
              raw_response = process.read
            end

            # Raise an error with the output from the shell session if dep
            # returns a non-zero status
            return if $CHILD_STATUS.success?
            raise SharedHelpers::HelperSubprocessFailed.new(
              raw_response,
              command
            )
          end

          def write_temporary_dependency_files
            dependency_files.each do |file|
              path = file.name
              FileUtils.mkdir_p(Pathname.new(path).dirname)
              File.write(file.name, file.content)
            end

            # Overwrite the manifest with our custom prepared one
            File.write(prepared_manifest.name, prepared_manifest.content)

            File.write("hello.go", dummy_app_content)
          end

          def prepared_manifest
            DependencyFile.new(
              name: manifest.name,
              content: prepared_manifest_content
            )
          end

          def prepared_manifest_content
            parsed_manifest = TomlRB.parse(manifest.content)

            dependencies.each do |dep|
              req = dep.requirements.find { |r| r[:file] == manifest.name }

              if req
                update_constraint!(parsed_manifest, dep)
              else
                create_constraint!(parsed_manifest, dep)
              end
            end

            TomlRB.dump(parsed_manifest)
          end

          # Used to lock the version when updating a top-level dependency
          def update_constraint!(parsed_manifest, dep)
            details =
              parsed_manifest.
              values_at(*FileParsers::Go::Dep::REQUIREMENT_TYPES).
              flatten.compact.find { |d| d["name"] == dep.name }

            req = dep.requirements.find { |r| r[:file] == manifest.name }

            details.delete("branch")

            if req.fetch(:source).fetch(:type) == "git"
              details.delete("version")
              details["revision"] = dep.version
            else
              details.delete("revision")
              details["version"] = dep.version
            end
          end

          # Used to lock the version when updating a subdependency
          def create_constraint!(parsed_manifest, dep)
            details = { "name" => dep.name }

            # Fetch the details from the lockfile to check whether this
            # sub-dependency needs a git revision or a version.
            original_details =
              parsed_file(lockfile).fetch("projects").
              find { |p| p["name"] == dep.name }

            if original_details["source"]
              details["source"] = original_details["source"]
            end

            if original_details["version"]
              details["version"] = dep.version
            else
              details["revision"] = dep.version
            end

            parsed_manifest["constraint"] << details
          end

          def go_dir
            # Work in a directory called "$HOME/go/src/dependabot-tmp".
            # TODO: This should pick up what the user's actual GOPATH is.
            go_dir = File.join(Dir.home, "go", "src", "dependabot-tmp")
            FileUtils.mkdir_p(go_dir)
            go_dir
          end

          def dummy_app_content
            base = "package main\n\n"\
                   "import \"fmt\"\n\n"

            dependencies_to_import.each { |nm| base += "import \"#{nm}\"\n\n" }

            base + "func main() {\n  fmt.Printf(\"hello, world\\n\")\n}"
          end

          def dependencies_to_import
            # There's no way to tell whether dependencies that appear in the
            # lockfile are there because they're imported themselves or because
            # they're sub-dependencies of something else. v0.5.0 will fix that
            # problem, but for now we just have to import everything.
            #
            # NOTE: This means the `inputs-digest` we generate will be wrong.
            # That's a pity, but we'd have to iterate through too many
            # possibilities to get it right. Again, this is fixed in v0.5.0.
            return [] unless lockfile
            TomlRB.parse(lockfile.content).fetch("projects").map do |detail|
              detail["name"]
            end
          end

          def parsed_file(file)
            @parsed_file ||= {}
            @parsed_file[file.name] ||= TomlRB.parse(file.content)
          end

          def manifest
            @manifest ||= dependency_files.find { |f| f.name == "Gopkg.toml" }
          end

          def lockfile
            @lockfile ||= dependency_files.find { |f| f.name == "Gopkg.lock" }
          end
        end
      end
    end
  end
end

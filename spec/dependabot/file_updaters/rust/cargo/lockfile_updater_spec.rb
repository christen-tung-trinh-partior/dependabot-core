# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/file_updaters/rust/cargo/lockfile_updater"

RSpec.describe Dependabot::FileUpdaters::Rust::Cargo::LockfileUpdater do
  let(:updater) do
    described_class.new(
      dependencies: [dependency],
      dependency_files: dependency_files,
      credentials: [{
        "type" => "git_source",
        "host" => "github.com",
        "username" => "x-access-token",
        "password" => "token"
      }]
    )
  end

  let(:dependency_files) { [manifest, lockfile] }
  let(:manifest) do
    Dependabot::DependencyFile.new(name: "Cargo.toml", content: manifest_body)
  end
  let(:lockfile) do
    Dependabot::DependencyFile.new(name: "Cargo.lock", content: lockfile_body)
  end
  let(:manifest_body) { fixture("rust", "manifests", manifest_fixture_name) }
  let(:lockfile_body) { fixture("rust", "lockfiles", lockfile_fixture_name) }
  let(:manifest_fixture_name) { "bare_version_specified" }
  let(:lockfile_fixture_name) { "bare_version_specified" }

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      requirements: requirements,
      previous_version: dependency_previous_version,
      previous_requirements: previous_requirements,
      package_manager: "cargo"
    )
  end
  let(:dependency_name) { "time" }
  let(:dependency_version) { "0.1.40" }
  let(:dependency_previous_version) { "0.1.38" }
  let(:requirements) { previous_requirements }
  let(:previous_requirements) do
    [{ file: "Cargo.toml", requirement: "0.1.12", groups: [], source: nil }]
  end
  let(:tmp_path) { Dependabot::SharedHelpers::BUMP_TMP_DIR_PATH }

  before { Dir.mkdir(tmp_path) unless Dir.exist?(tmp_path) }

  describe "#updated_lockfile_content" do
    subject(:updated_lockfile_content) { updater.updated_lockfile_content }

    it "doesn't store the files permanently" do
      expect { updated_lockfile_content }.
        to_not(change { Dir.entries(tmp_path) })
    end

    it { expect { updated_lockfile_content }.to_not output.to_stdout }

    context "when updating the lockfile fails" do
      let(:dependency_version) { "99.0.0" }
      let(:requirements) do
        [{ file: "Cargo.toml", requirement: "99", groups: [], source: nil }]
      end

      it "raises a helpful error" do
        expect { updater.updated_lockfile_content }.
          to raise_error do |error|
            expect(error).
              to be_a(Dependabot::SharedHelpers::HelperSubprocessFailed)
            expect(error.message).to include("no matching version")
          end
      end

      context "because an existing requirement is no good" do
        let(:manifest_fixture_name) { "yanked_version" }
        let(:lockfile_fixture_name) { "yanked_version" }

        it "raises a helpful error" do
          expect { updater.updated_lockfile_content }.
            to raise_error do |error|
              expect(error).to be_a(Dependabot::DependencyFileNotResolvable)
              expect(error.message).
                to include("version `^99.0.0` found for package `regex`")
            end
        end
      end
    end

    describe "the updated lockfile" do
      it "updates the dependency version in the lockfile" do
        expect(updated_lockfile_content).
          to include(%(name = "time"\nversion = "0.1.40"))
        expect(updated_lockfile_content).to include(
          "d825be0eb33fda1a7e68012d51e9c7f451dc1a69391e7fdc197060bb8c56667b"
        )
        expect(updated_lockfile_content).to_not include(
          "d5d788d3aa77bc0ef3e9621256885555368b47bd495c13dd2e7413c89f845520"
        )
      end

      context "with a blank requirement" do
        let(:manifest_fixture_name) { "blank_version" }
        let(:lockfile_fixture_name) { "blank_version" }
        let(:previous_requirements) do
          [{ file: "Cargo.toml", requirement: nil, groups: [], source: nil }]
        end

        it "updates the dependency version in the lockfile" do
          expect(updated_lockfile_content).
            to include(%(name = "time"\nversion = "0.1.40"))
        end
      end

      context "with multiple versions available of the dependency" do
        let(:manifest_fixture_name) { "multiple_versions" }
        let(:lockfile_fixture_name) { "multiple_versions" }

        let(:dependency_name) { "rand" }
        let(:dependency_version) { "0.4.2" }
        let(:dependency_previous_version) { "0.4.1" }
        let(:requirements) { previous_requirements }
        let(:previous_requirements) do
          [{
            file: "Cargo.toml",
            requirement: "0.4",
            groups: [],
            source: nil
          }]
        end

        it "updates the dependency version in the lockfile" do
          expect(updated_lockfile_content).
            to include(%(name = "rand"\nversion = "0.4.2"))
        end
      end

      context "with a git dependency" do
        let(:manifest_fixture_name) { "git_dependency" }
        let(:lockfile_fixture_name) { "git_dependency" }

        let(:dependency_name) { "utf8-ranges" }
        let(:dependency_version) do
          "1024c5074ced00aad1a83be4d10119b39d2151bd"
        end
        let(:dependency_previous_version) do
          "83141b376b93484341c68fbca3ca110ae5cd2708"
        end
        let(:requirements) { previous_requirements }
        let(:previous_requirements) do
          [{
            file: "Cargo.toml",
            requirement: nil,
            groups: ["dependencies"],
            source: {
              type: "git",
              url: "https://github.com/BurntSushi/utf8-ranges",
              branch: nil,
              ref: nil
            }
          }]
        end

        it "updates the dependency version in the lockfile" do
          expect(updated_lockfile_content).
            to include("utf8-ranges#1024c5074ced00aad1a83be4d10119b39d2151bd")
        end

        context "with an ssh URl" do
          let(:manifest_fixture_name) { "git_dependency_ssh" }
          let(:lockfile_fixture_name) { "git_dependency_ssh" }
          let(:requirements) { previous_requirements }
          let(:previous_requirements) do
            [{
              file: "Cargo.toml",
              requirement: nil,
              groups: ["dependencies"],
              source: {
                type: "git",
                url: "ssh://git@github.com/BurntSushi/utf8-ranges",
                branch: nil,
                ref: nil
              }
            }]
          end

          it "updates the dependency version in the lockfile" do
            expect(updated_lockfile_content).
              to include("git+ssh://git@github.com/BurntSushi/utf8-ranges#"\
                         "1024c5074ced00aad1a83be4d10119b39d2151bd")
            expect(updated_lockfile_content).to_not include("git+https://")
          end
        end

        context "with an updated tag" do
          let(:manifest_fixture_name) { "git_dependency_with_tag" }
          let(:lockfile_fixture_name) { "git_dependency_with_tag" }
          let(:dependency_version) do
            "83141b376b93484341c68fbca3ca110ae5cd2708"
          end
          let(:dependency_previous_version) do
            "d5094c7e9456f2965dec20de671094a98c6929c2"
          end
          let(:requirements) do
            [{
              file: "Cargo.toml",
              requirement: nil,
              groups: ["dependencies"],
              source: {
                type: "git",
                url: "https://github.com/BurntSushi/utf8-ranges",
                branch: nil,
                ref: "1.0.0"
              }
            }]
          end
          let(:previous_requirements) do
            [{
              file: "Cargo.toml",
              requirement: nil,
              groups: ["dependencies"],
              source: {
                type: "git",
                url: "https://github.com/BurntSushi/utf8-ranges",
                branch: nil,
                ref: "0.1.3"
              }
            }]
          end

          it "updates the dependency version in the lockfile" do
            expect(updated_lockfile_content).
              to include "?tag=1.0.0#83141b376b93484341c68fbca3ca110ae5cd2708"
          end
        end
      end

      context "when there is a path dependency" do
        let(:dependency_files) { [manifest, lockfile, path_dependency_file] }
        let(:manifest_fixture_name) { "path_dependency" }
        let(:lockfile_fixture_name) { "path_dependency" }
        let(:dependency) do
          Dependabot::Dependency.new(
            name: "regex",
            version: "0.2.10",
            requirements: [{
              file: "Cargo.toml",
              requirement: "=0.2.10",
              groups: [],
              source: nil
            }],
            previous_version: "0.1.38",
            previous_requirements: [{
              file: "Cargo.toml",
              requirement: "=0.1.38",
              groups: [],
              source: nil
            }],
            package_manager: "cargo"
          )
        end
        let(:path_dependency_file) do
          Dependabot::DependencyFile.new(
            name: "src/s3/Cargo.toml",
            content: fixture("rust", "manifests", "cargo-registry-s3")
          )
        end

        it "updates the dependency version in the lockfile" do
          expect(updated_lockfile_content).
            to include(%(name = "regex"\nversion = "0.2.10"))
          expect(updated_lockfile_content).to include(
            "aec3f58d903a7d2a9dc2bf0e41a746f4530e0cab6b615494e058f67a3ef947fb"
          )
          expect(updated_lockfile_content).to_not include(
            "bc2a4457b0c25dae6fee3dcd631ccded31e97d689b892c26554e096aa08dd136"
          )
        end
      end

      context "when there is a workspace" do
        let(:dependency_files) { [manifest, lockfile, workspace_child] }
        let(:manifest_fixture_name) { "workspace_root" }
        let(:lockfile_fixture_name) { "workspace" }
        let(:workspace_child) do
          Dependabot::DependencyFile.new(
            name: "lib/sub_crate/Cargo.toml",
            content: fixture("rust", "manifests", "workspace_child")
          )
        end
        let(:dependency) do
          Dependabot::Dependency.new(
            name: "log",
            version: "0.4.1",
            requirements: [{
              requirement: "=0.4.1",
              file: "lib/sub_crate/Cargo.toml",
              groups: ["dependencies"],
              source: nil
            }],
            previous_version: "0.4.0",
            previous_requirements: [{
              requirement: "=0.4.0",
              file: "lib/sub_crate/Cargo.toml",
              groups: ["dependencies"],
              source: nil
            }],
            package_manager: "cargo"
          )
        end

        it "updates the dependency version in the lockfile" do
          expect(updated_lockfile_content).
            to include(%(name = "log"\nversion = "0.4.1"))
          expect(updated_lockfile_content).to include(
            "89f010e843f2b1a31dbd316b3b8d443758bc634bed37aabade59c686d644e0a2"
          )
          expect(updated_lockfile_content).to_not include(
            "b3a89a0c46ba789b8a247d4c567aed4d7c68e624672d238b45cc3ec20dc9f940"
          )
        end
      end
    end
  end
end

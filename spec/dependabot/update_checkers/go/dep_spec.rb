# frozen_string_literal: true

require "dependabot/update_checkers/go/dep"
require_relative "../shared_examples_for_update_checkers"

RSpec.describe Dependabot::UpdateCheckers::Go::Dep do
  it_behaves_like "an update checker"

  let(:checker) do
    described_class.new(
      dependency: dependency,
      dependency_files: dependency_files,
      credentials: credentials,
      ignored_versions: ignored_versions
    )
  end

  let(:ignored_versions) { [] }
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end
  let(:dependency_files) do
    [
      Dependabot::DependencyFile.new(
        name: "Gopkg.toml",
        content: fixture("go", "gopkg_tomls", manifest_fixture_name)
      ),
      Dependabot::DependencyFile.new(
        name: "Gopkg.lock",
        content: fixture("go", "gopkg_locks", lockfile_fixture_name)
      )
    ]
  end
  let(:manifest_fixture_name) { "no_version.toml" }
  let(:lockfile_fixture_name) { "no_version.lock" }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      requirements: requirements,
      package_manager: "dep"
    )
  end
  let(:requirements) do
    [{ file: "Gopkg.toml", requirement: req_str, groups: [], source: source }]
  end
  let(:dependency_name) { "golang.org/x/text" }
  let(:dependency_version) { "0.2.0" }
  let(:req_str) { nil }
  let(:source) { { type: "default", source: "golang.org/x/text" } }

  let(:service_pack_url) do
    "https://github.com/golang/text.git/info/refs"\
    "?service=git-upload-pack"
  end
  before do
    stub_request(:get, service_pack_url).
      to_return(
        status: 200,
        body: fixture("git", "upload_packs", upload_pack_fixture),
        headers: {
          "content-type" => "application/x-git-upload-pack-advertisement"
        }
      )
  end
  let(:upload_pack_fixture) { "text" }

  describe "#latest_version" do
    subject { checker.latest_version }

    it "delegates to LatestVersionFinder" do
      expect(described_class::LatestVersionFinder).to receive(:new).with(
        dependency: dependency,
        dependency_files: dependency_files,
        credentials: credentials,
        ignored_versions: ignored_versions
      ).and_call_original

      expect(checker.latest_version).to eq(Gem::Version.new("0.3.0"))
    end
  end

  describe "#latest_resolvable_version" do
    subject { checker.latest_resolvable_version }

    it "delegates to VersionResolver" do
      prepped_files = described_class::FilePreparer.new(
        dependency_files: dependency_files,
        dependency: dependency,
        unlock_requirement: true,
        remove_git_source: false,
        latest_allowable_version: Gem::Version.new("0.3.0")
      ).prepared_dependency_files

      expect(described_class::VersionResolver).to receive(:new).with(
        dependency: dependency,
        dependency_files: prepped_files,
        credentials: credentials
      ).and_call_original

      expect(checker.latest_resolvable_version).to eq(Gem::Version.new("0.3.0"))
    end

    context "with a manifest file that needs unlocking" do
      let(:manifest_fixture_name) { "bare_version.toml" }
      let(:lockfile_fixture_name) { "bare_version.lock" }
      let(:req_str) { "0.2.0" }

      it "unlocks the manifest and gets the correct version" do
        expect(checker.latest_resolvable_version).
          to eq(Gem::Version.new("0.3.0"))
      end
    end
  end

  describe "#latest_resolvable_version_with_no_unlock" do
    subject { checker.latest_resolvable_version_with_no_unlock }

    it "delegates to VersionResolver" do
      prepped_files = described_class::FilePreparer.new(
        dependency_files: dependency_files,
        dependency: dependency,
        unlock_requirement: true,
        remove_git_source: false,
        latest_allowable_version: Gem::Version.new("0.3.0")
      ).prepared_dependency_files

      expect(described_class::VersionResolver).to receive(:new).with(
        dependency: dependency,
        dependency_files: prepped_files,
        credentials: credentials
      ).and_call_original

      expect(checker.latest_resolvable_version_with_no_unlock).
        to eq(Gem::Version.new("0.3.0"))
    end

    context "with a manifest file that needs unlocking" do
      let(:manifest_fixture_name) { "bare_version.toml" }
      let(:lockfile_fixture_name) { "bare_version.lock" }
      let(:req_str) { "0.2.0" }

      it "doesn't unlock the manifest" do
        expect(checker.latest_resolvable_version_with_no_unlock).
          to eq(Gem::Version.new("0.2.0"))
      end
    end
  end
end

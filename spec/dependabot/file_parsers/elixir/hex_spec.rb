# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency_file"
require "dependabot/file_parsers/elixir/hex"
require_relative "../shared_examples_for_file_parsers"

RSpec.describe Dependabot::FileParsers::Elixir::Hex do
  it_behaves_like "a dependency file parser"

  let(:files) { [mixfile, lockfile] }
  let(:mixfile) do
    Dependabot::DependencyFile.new(name: "mix.exs", content: mixfile_body)
  end
  let(:lockfile) do
    Dependabot::DependencyFile.new(name: "mix.lock", content: lockfile_body)
  end
  let(:mixfile_body) { fixture("elixir", "mixfiles", "minor_version") }
  let(:lockfile_body) { fixture("elixir", "lockfiles", "minor_version") }
  let(:parser) { described_class.new(dependency_files: files, repo: "org/nm") }

  describe "parse" do
    subject(:dependencies) { parser.parse }

    context "with a ~> version specified" do
      its(:length) { is_expected.to eq(2) }

      describe "the last dependency" do
        subject(:dependency) { dependencies.last }

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("plug")
          expect(dependency.version).to eq("1.3.5")
          expect(dependency.requirements).to eq(
            [
              {
                requirement: "~> 1.3.0",
                file: "mix.exs",
                groups: [],
                source: nil
              }
            ]
          )
        end
      end
    end

    context "with an exact version specified" do
      let(:mixfile_body) { fixture("elixir", "mixfiles", "exact_version") }
      let(:lockfile_body) { fixture("elixir", "lockfiles", "exact_version") }

      its(:length) { is_expected.to eq(2) }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("phoenix")
          expect(dependency.version).to eq("1.2.1")
          expect(dependency.requirements).to eq(
            [
              {
                requirement: "== 1.2.1",
                file: "mix.exs",
                groups: [],
                source: nil
              }
            ]
          )
        end
      end

      describe "the second dependency" do
        subject(:dependency) { dependencies.last }

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("plug")
          expect(dependency.version).to eq("1.3.0")
          expect(dependency.requirements).to eq(
            [
              {
                requirement: "1.3.0",
                file: "mix.exs",
                groups: [],
                source: nil
              }
            ]
          )
        end
      end
    end

    context "with a git source" do
      let(:mixfile_body) { fixture("elixir", "mixfiles", "git_source") }
      let(:lockfile_body) { fixture("elixir", "lockfiles", "git_source") }

      its(:length) { is_expected.to eq(1) }

      describe "the dependency" do
        subject(:dependency) { dependencies.first }

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("plug")
          expect(dependency.version).to eq("1.2.0")
          expect(dependency.requirements).to eq(
            [
              {
                requirement: "1.2.0",
                file: "mix.exs",
                groups: [],
                source: nil
              }
            ]
          )
        end
      end
    end

    context "with an old elixir version" do
      let(:mixfile_body) { fixture("elixir", "mixfiles", "old_elixir") }
      let(:lockfile_body) { fixture("elixir", "lockfiles", "old_elixir") }

      its(:length) { is_expected.to eq(2) }
    end

    context "with a call to read a version file" do
      let(:mixfile_body) { fixture("elixir", "mixfiles", "loads_file") }
      let(:lockfile_body) { fixture("elixir", "lockfiles", "exact_version") }

      its(:length) { is_expected.to eq(2) }
    end

    context "with a bad specification" do
      let(:mixfile_body) { fixture("elixir", "mixfiles", "bad_spec") }
      let(:lockfile_body) { fixture("elixir", "lockfiles", "exact_version") }

      its(:length) { is_expected.to eq(2) }
    end

    context "with an umbrella app" do
      let(:mixfile_body) { fixture("elixir", "mixfiles", "umbrella") }
      let(:lockfile_body) { fixture("elixir", "lockfiles", "umbrella") }
      let(:files) { [mixfile, lockfile, sub_mixfile1, sub_mixfile2] }
      let(:sub_mixfile1) do
        Dependabot::DependencyFile.new(
          name: "apps/dependabot_business/mix.exs",
          content: fixture("elixir", "mixfiles", "dependabot_business")
        )
      end
      let(:sub_mixfile2) do
        Dependabot::DependencyFile.new(
          name: "apps/dependabot_web/mix.exs",
          content: fixture("elixir", "mixfiles", "dependabot_web")
        )
      end

      it "parses the dependencies correctly" do
        expect(dependencies.length).to eq(3)
        expect(dependencies).to include(
          Dependabot::Dependency.new(
            name: "jason",
            version: "1.0.0",
            requirements: [
              {
                requirement: "~> 1.0",
                file: "apps/dependabot_business/mix.exs",
                groups: [],
                source: nil
              }
            ],
            package_manager: "hex"
          )
        )
        expect(dependencies).to include(
          Dependabot::Dependency.new(
            name: "plug",
            version: "1.3.6",
            requirements: [
              {
                requirement: "1.3.6",
                file: "apps/dependabot_web/mix.exs",
                groups: [],
                source: nil
              },
              {
                requirement: "~> 1.3.0",
                file: "apps/dependabot_business/mix.exs",
                groups: [],
                source: nil
              }
            ],
            package_manager: "hex"
          )
        )
        expect(dependencies).to include(
          Dependabot::Dependency.new(
            name: "distillery",
            version: "1.5.2",
            requirements: [
              {
                requirement: "~> 1.5",
                file: "mix.exs",
                groups: [],
                source: nil
              }
            ],
            package_manager: "hex"
          )
        )
      end
    end
  end
end

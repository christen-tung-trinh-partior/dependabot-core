# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/update_checkers/python/pip/pipfile_version_resolver"

namespace = Dependabot::UpdateCheckers::Python::Pip
RSpec.describe namespace::PipfileVersionResolver do
  let(:resolver) do
    described_class.new(
      dependency: dependency,
      dependency_files: dependency_files,
      credentials: credentials
    )
  end
  let(:credentials) do
    [{
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end
  let(:dependency_files) { [pipfile, lockfile] }
  let(:pipfile) do
    Dependabot::DependencyFile.new(
      name: "Pipfile",
      content: fixture("python", "pipfiles", pipfile_fixture_name)
    )
  end
  let(:pipfile_fixture_name) { "exact_version" }
  let(:lockfile) do
    Dependabot::DependencyFile.new(
      name: "Pipfile.lock",
      content: fixture("python", "lockfiles", lockfile_fixture_name)
    )
  end
  let(:lockfile_fixture_name) { "exact_version.lock" }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      requirements: dependency_requirements,
      package_manager: "pip"
    )
  end
  let(:dependency_name) { "requests" }
  let(:dependency_version) { "2.18.0" }
  let(:dependency_requirements) do
    [{
      file: "Pipfile",
      requirement: "==2.18.0",
      groups: ["default"],
      source: nil
    }]
  end

  describe "#latest_resolvable_version" do
    subject { resolver.latest_resolvable_version }

    context "with a lockfile" do
      let(:dependency_files) { [pipfile, lockfile] }
      let(:dependency_version) { "2.18.0" }
      it { is_expected.to be >= Gem::Version.new("2.18.4") }
    end

    context "without a lockfile" do
      let(:dependency_files) { [pipfile] }
      let(:dependency_version) { nil }
      it { is_expected.to be >= Gem::Version.new("2.18.4") }
    end

    context "with a path dependency" do
      let(:dependency_files) { [pipfile, lockfile, setupfile] }
      let(:setupfile) do
        Dependabot::DependencyFile.new(
          name: "setup.py",
          content: fixture("python", "setup_files", setupfile_fixture_name)
        )
      end
      let(:setupfile_fixture_name) { "small.py" }
      let(:pipfile_fixture_name) { "path_dependency" }
      let(:lockfile_fixture_name) { "path_dependency.lock" }
      it { is_expected.to be >= Gem::Version.new("2.18.4") }
    end

    context "with a required python version" do
      let(:pipfile_fixture_name) { "required_python" }
      let(:lockfile_fixture_name) { "required_python.lock" }
      it { is_expected.to be >= Gem::Version.new("2.18.4") }
    end

    context "with a toml format that Pipenv can't handle" do
      let(:pipfile_fixture_name) { "parser_bug" }
      it "raises a helpful error" do
        expect { subject }.
          to raise_error(Dependabot::DependencyFileNotParseable) do |error|
            expect(error.file_path).to eq("/Pipfile")
          end
      end
    end

    context "with an unreachable private source" do
      let(:pipfile_fixture_name) { "private_source" }
      let(:lockfile_fixture_name) { "exact_version.lock" }

      before do
        stub_request(:get, "https://some.internal.registry.com/pypi/requests/").
          to_raise(Excon::Error::Timeout)
      end

      it "raises a helpful error" do
        expect { subject }.
          to raise_error(Dependabot::PrivateSourceNotReachable) do |error|
            expect(error.source).
              to eq("https://some.internal.registry.com/pypi/")
          end
      end

      context "from credentials" do
        let(:pipfile_fixture_name) { "exact_version" }
        let(:credentials) do
          [
            {
              "host" => "github.com",
              "username" => "x-access-token",
              "password" => "token"
            },
            {
              "index-url" => "https://user:pass@pypi.gemfury.com/secret_codes/"
            }
          ]
        end

        before do
          stub_request(:get, "https://pypi.gemfury.com/secret_codes/requests/").
            to_raise(Excon::Error::Timeout)
        end

        it "raises a helpful error" do
          expect { subject }.
            to raise_error(Dependabot::PrivateSourceNotReachable) do |error|
              expect(error.source).
                to eq("https://redacted@pypi.gemfury.com/secret_codes/")
            end
        end
      end
    end

    context "with an environment variable source" do
      let(:pipfile_fixture_name) { "environment_variable_source" }
      let(:lockfile_fixture_name) { "environment_variable_source.lock" }

      context "with no credentials" do
        it "raises a helpful error" do
          expect { subject }.
            to raise_error(Dependabot::PrivateSourceNotReachable) do |error|
              expect(error.source).to eq("https://pypi.python.org/${ENV_VAR}/")
            end
        end
      end

      context "with a non-matching credential" do
        let(:credentials) do
          [
            {
              "host" => "github.com",
              "username" => "x-access-token",
              "password" => "token"
            },
            {
              "index-url" => "https://pypi.gemfury.com/secret_codes/"
            }
          ]
        end
        it "raises a helpful error" do
          expect { subject }.
            to raise_error(Dependabot::PrivateSourceNotReachable) do |error|
              expect(error.source).to eq("https://pypi.python.org/${ENV_VAR}/")
            end
        end
      end

      context "with a matching credential" do
        let(:credentials) do
          [
            {
              "host" => "github.com",
              "username" => "x-access-token",
              "password" => "token"
            },
            {
              "index-url" => "https://pypi.python.org/simple"
            }
          ]
        end

        it { is_expected.to be >= Gem::Version.new("2.18.4") }
      end
    end

    context "with a `nil` requirement" do
      let(:dependency_files) { [pipfile] }
      let(:dependency_version) { nil }
      let(:dependency_requirements) do
        [
          {
            file: "Pipfile",
            requirement: "==2.18.0",
            groups: ["default"],
            source: nil
          },
          {
            file: "requirements.txt",
            requirement: nil,
            groups: ["default"],
            source: nil
          }
        ]
      end
      it { is_expected.to be >= Gem::Version.new("2.18.4") }
    end

    context "with a conflict at the latest version" do
      let(:pipfile_fixture_name) { "conflict_at_latest" }
      let(:lockfile_fixture_name) { "conflict_at_latest.lock" }
      let(:dependency_version) { "2.6.0" }
      let(:dependency_requirements) do
        [{
          file: "Pipfile",
          requirement: "==2.6.0",
          groups: ["default"],
          source: nil
        }]
      end

      it { is_expected.to be_nil }
    end
  end
end

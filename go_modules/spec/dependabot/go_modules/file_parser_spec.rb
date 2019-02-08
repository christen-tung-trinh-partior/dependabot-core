# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency_file"
require "dependabot/source"
require "dependabot/dependency"
require "dependabot/go_modules/file_parser"
require_common_spec "file_parsers/shared_examples_for_file_parsers"

RSpec.describe Dependabot::GoModules::FileParser do
  it_behaves_like "a dependency file parser"

  let(:parser) { described_class.new(dependency_files: files, source: source) }
  let(:files) { [go_mod] }
  let(:go_mod) do
    Dependabot::DependencyFile.new(
      name: "go.mod",
      content: go_mod_content
    )
  end
  let(:go_mod_content) { fixture("go_mods", go_mod_fixture_name) }
  let(:go_mod_fixture_name) { "go.mod" }
  let(:source) do
    Dependabot::Source.new(
      provider: "github",
      repo: "gocardless/bump",
      directory: "/"
    )
  end

  it "requires a go.mod to be present" do
    expect do
      described_class.new(dependency_files: [], source: source)
    end.to raise_error(RuntimeError)
  end

  describe "parse" do
    subject(:dependencies) { parser.parse }

    its(:length) { is_expected.to eq(5) }

    describe "top level dependencies" do
      subject(:dependencies) do
        parser.parse.select(&:top_level?)
      end

      its(:length) { is_expected.to eq(2) }

      describe "a dependency that uses go modules" do
        subject(:dependency) do
          dependencies.find { |d| d.name == "rsc.io/quote" }
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("rsc.io/quote")
          expect(dependency.version).to eq("1.4.0")
          expect(dependency.requirements).to eq(
            [{
              requirement: "v1.4.0",
              file: "go.mod",
              groups: [],
              source: {
                type: "default",
                source: "rsc.io/quote"
              }
            }]
          )
        end
      end

      describe "a dependency that doesn't use go modules" do
        subject(:dependency) do
          dependencies.find { |d| d.name == "github.com/fatih/Color" }
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("github.com/fatih/Color")
          expect(dependency.version).to eq("1.7.0")
          expect(dependency.requirements).to eq(
            [{
              requirement: "v1.7.0",
              file: "go.mod",
              groups: [],
              source: {
                type: "default",
                source: "github.com/fatih/Color"
              }
            }]
          )
        end
      end

      context "with git dependencies" do
        let(:go_mod_fixture_name) { "git_dependency.mod" }

        describe "a git revision dependency" do
          subject(:dependency) do
            dependencies.find { |d| d.name == "golang.org/x/crypto" }
          end

          it "has the right details" do
            expect(dependency).to be_a(Dependabot::Dependency)
            expect(dependency.name).to eq("golang.org/x/crypto")
            expect(dependency.version).
              to eq("0.0.0-20180617042118-027cca12c2d6")
            expect(dependency.requirements).to eq(
              [{
                requirement: nil,
                file: "go.mod",
                groups: [],
                source: {
                  type: "git",
                  url: "https://github.com/golang/crypto",
                  ref: "027cca12c2d6",
                  branch: nil
                }
              }]
            )
          end
        end
      end
    end

    describe "a garbage go.mod" do
      let(:go_mod_content) { "not really a go.mod file :-/" }

      it "raises the correct error" do
        expect { parser.parse }.
          to raise_error(Dependabot::DependencyFileNotParseable) do |error|
            expect(error.file_path).to eq("/go.mod")
          end
      end
    end

    describe "a non-existent dependency" do
      let(:go_mod_content) do
        go_mod = fixture("go_mods", go_mod_fixture_name)
        go_mod.sub("rsc.io/quote", "example.com/not-a-repo")
      end

      it "raises the correct error" do
        expect { parser.parse }.
          to raise_error(Dependabot::DependencyFileNotResolvable)
      end
    end

    describe "a dependency at a non-existent version" do
      let(:go_mod_content) do
        go_mod = fixture("go_mods", go_mod_fixture_name)
        go_mod.sub("rsc.io/quote v1.4.0", "rsc.io/quote v1.321.0")
      end

      it "raises the correct error" do
        expect { parser.parse }.
          to raise_error(Dependabot::DependencyFileNotResolvable)
      end
    end

    describe "a non-semver vanity URL that 404s but includes meta tags" do
      subject(:dependency) do
        dependencies.find { |d| d.name == "gonum.org/v1/plot" }
      end

      let(:go_mod_content) do
        go_mod = fixture("go_mods", go_mod_fixture_name)
        go_mod.sub("rsc.io/quote v1.4.0",
                   "gonum.org/v1/plot v0.0.0-20181116082555-59819fff2fb9")
      end

      it "has the right details" do
        expect(dependency).to be_a(Dependabot::Dependency)
        expect(dependency.name).to eq("gonum.org/v1/plot")
      end
    end

    describe "a v2+ dependency without the major version in the path" do
      let(:go_mod_content) do
        go_mod = fixture("go_mods", go_mod_fixture_name)
        go_mod.sub("rsc.io/quote v1.4.0", "rsc.io/quote v2.0.0")
      end

      it "raises the correct error" do
        expect { parser.parse }.
          to raise_error(Dependabot::DependencyFileNotParseable) do |error|
            expect(error.file_path).to eq("/go.mod")
            expect(error.message).to match(/v0 or v1/)
          end
      end
    end
  end
end

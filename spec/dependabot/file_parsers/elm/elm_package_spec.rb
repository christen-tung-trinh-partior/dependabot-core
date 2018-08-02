# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency_file"
require "dependabot/file_parsers/elm/elm_package"
require_relative "../shared_examples_for_file_parsers"

RSpec.describe Dependabot::FileParsers::Elm::ElmPackage do
  def elm_version(version_string)
    Dependabot::Utils::Elm::Version.new(version_string)
  end
  let(:max_version) { Dependabot::FileParsers::Elm::ElmPackage::MAX_VERSION }
  it_behaves_like "a dependency file parser"

  let(:files) { [elm_package] }
  let(:elm_package) do
    Dependabot::DependencyFile.new(
      name: "elm-package.json",
      content: fixture("elm", "elm_package", elm_package_fixture_name)
    )
  end
  let(:elm_package_fixture_name) { "one_fixture_to_test_them_all" }
  let(:parser) { described_class.new(dependency_files: files, source: source) }
  let(:source) do
    Dependabot::Source.new(
      provider: "github",
      repo: "NoRedInk/noredink-ui",
      directory: "/"
    )
  end

  describe "parse" do
    subject(:dependencies) { parser.parse.group_by(&:name) }
    its(:length) { is_expected.to eq(4) }

    context "dependency" do
      subject(:dependency) { dependencies[dependency_name].first }
      context "with <=" do
        let(:dependency_name) { "realWorldElmPackage/withOrEqualsUpperBound" }

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.version).to eq(elm_version("2.2.0"))
          expect(dependency.requirements).to eq(
            [{
              requirement: "2.0.0 <= v <= 2.2.0",
              file: "elm-package.json",
              groups: nil,
              source: nil
            }]
          )
        end
      end
      context "with <" do
        context "with 1.0.1" do
          let(:dependency_name) { "realWorldElmPackage/withMinimumUpperBound" }

          it "has the right details" do
            expect(dependency).to be_a(Dependabot::Dependency)
            expect(dependency.version).to eq(elm_version("1.0.0"))
            expect(dependency.requirements).to eq(
              [{
                requirement: "1.0.0 <= v < 1.0.1",
                file: "elm-package.json",
                groups: nil,
                source: nil
              }]
            )
          end
        end

        context "with 1.1.0" do
          let(:dependency_name) do
            "realWorldElmPackage/withZeroPatchUpperBound"
          end

          it "has the right details" do
            expect(dependency).to be_a(Dependabot::Dependency)
            expect(dependency.version).to eq(elm_version("1.0.#{max_version}"))
            expect(dependency.requirements).to eq(
              [{
                requirement: "1.0.0 <= v < 1.1.0",
                file: "elm-package.json",
                groups: nil,
                source: nil
              }]
            )
          end
        end

        # Not testing 1.0.0 because < 1.0.0 is already an invalid constraint.
        # Elm packages start at 1.0.0

        context "with 2.0.0" do
          let(:dependency_name) do
            "realWorldElmPackage/withZeroMinorUpperBound"
          end

          it "has the right details" do
            expect(dependency).to be_a(Dependabot::Dependency)
            expect(dependency.version).
              to eq(elm_version("1.#{max_version}.#{max_version}"))
            expect(dependency.requirements).to eq(
              [{
                requirement: "1.0.0 <= v < 2.0.0",
                file: "elm-package.json",
                groups: nil,
                source: nil
              }]
            )
          end
        end
      end
    end
  end
end

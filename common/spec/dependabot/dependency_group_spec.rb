# frozen_string_literal: true

require "dependabot/dependency_group"
require "dependabot/dependency"

# TODO: Once the Updater has been merged into Core, we should test this
# using the DependencyGroupEngine methods instead of mocking the functionality
RSpec.describe Dependabot::DependencyGroup do
  let(:dependency_group) { described_class.new(name: name, rules: rules) }
  let(:name) { "test_group" }
  let(:rules) { { "patterns" => ["test-*"] } }

  let(:test_dependency1) do
    Dependabot::Dependency.new(
      name: "test-dependency-1",
      package_manager: "bundler",
      version: "1.1.0",
      requirements: [
        {
          file: "Gemfile",
          requirement: "~> 1.1.0",
          groups: ["test"],
          source: nil
        }
      ]
    )
  end

  let(:test_dependency2) do
    Dependabot::Dependency.new(
      name: "test-dependency-2",
      package_manager: "bundler",
      version: "1.1.0",
      requirements: [
        {
          file: "Gemfile",
          requirement: "~> 1.1.0",
          groups: ["test"],
          source: nil
        }
      ]
    )
  end

  let(:production_dependency) do
    Dependabot::Dependency.new(
      name: "another-dependency",
      package_manager: "bundler",
      version: "1.1.0",
      requirements: [
        {
          file: "Gemfile",
          requirement: "~> 1.1.0",
          groups: ["default"],
          source: nil
        }
      ]
    )
  end

  # Mock out the dependency-type == production check for Bundler
  let(:production_checker) do
    lambda do |gemfile_groups|
      return true if gemfile_groups.empty?
      return true if gemfile_groups.include?("runtime")
      return true if gemfile_groups.include?("default")

      gemfile_groups.any? { |g| g.include?("prod") }
    end
  end

  before do
    allow(Dependabot::Dependency).to receive(:production_check_for_package_manager).and_return(production_checker)
  end

  describe "#name" do
    it "returns the name" do
      expect(dependency_group.name).to eq(name)
    end
  end

  describe "#rules" do
    it "returns a list of rules" do
      expect(dependency_group.rules).to eq(rules)
    end
  end

  describe "#dependencies" do
    context "when no dependencies are assigned to the group" do
      it "returns an empty list" do
        expect(dependency_group.dependencies).to eq([])
      end
    end

    context "when dependencies have been assigned" do
      before do
        dependency_group.dependencies << test_dependency1
      end

      it "returns the dependencies" do
        expect(dependency_group.dependencies).to include(test_dependency1)
        expect(dependency_group.dependencies).not_to include(test_dependency2)
      end
    end
  end

  describe "#contains?" do
    context "when the rules include patterns" do
      let(:rules) do
        {
          "patterns" => ["test-*", "nothing-matches-this"],
          "exclude-patterns" => ["*-2"]
        }
      end

      context "before dependencies are assigned to the group" do
        it "returns true if the dependency matches a pattern" do
          expect(dependency_group.dependencies).to eq([])
          expect(dependency_group.contains?(test_dependency1)).to be_truthy
        end

        it "returns false if the dependency is specifically excluded" do
          expect(dependency_group.dependencies).to eq([])
          expect(dependency_group.contains?(test_dependency2)).to be_falsey
        end

        it "returns false if the dependency does not match any patterns" do
          expect(dependency_group.dependencies).to eq([])
          expect(dependency_group.contains?(production_dependency)).to be_falsey
        end
      end

      context "after dependencies are assigned to the group" do
        before do
          dependency_group.dependencies << test_dependency1
        end

        it "returns true if the dependency is in the dependency list" do
          expect(dependency_group.dependencies).to include(test_dependency1)
          expect(dependency_group.contains?(test_dependency1)).to be_truthy
        end

        it "returns false if the dependency is specifically excluded" do
          expect(dependency_group.dependencies).to include(test_dependency1)
          expect(dependency_group.contains?(test_dependency2)).to be_falsey
        end

        it "returns false if the dependency is not in the dependency list and does not match a pattern" do
          expect(dependency_group.dependencies).to include(test_dependency1)
          expect(dependency_group.contains?(production_dependency)).to be_falsey
        end
      end
    end

    context "when the rules specify a dependency-type" do
      let(:rules) do
        {
          "dependency-type" => "production"
        }
      end

      it "returns true if the dependency matches the specified type" do
        expect(dependency_group.contains?(production_dependency)).to be_truthy
      end

      it "returns false if the dependency does not match the specified type" do
        expect(dependency_group.contains?(test_dependency1)).to be_falsey
        expect(dependency_group.contains?(test_dependency2)).to be_falsey
      end

      context "when a dependency is specifically excluded" do
        let(:rules) do
          {
            "dependency-type" => "production",
            "exclude-patterns" => [production_dependency.name]
          }
        end

        it "returns false even if the dependency matches the specified type" do
          expect(dependency_group.contains?(production_dependency)).to be_falsey
        end
      end
    end

    context "when the rules specify a mix of patterns and dependency-types" do
      let(:rules) do
        {
          "patterns" => ["*dependency*"],
          "exclude-patterns" => ["*-2"],
          "dependency-type" => "development"
        }
      end

      it "returns true if the dependency matches the specified type and a pattern" do
        expect(dependency_group.contains?(test_dependency1)).to be_truthy
      end

      it "returns false if the dependency only matches the pattern" do
        expect(dependency_group.contains?(production_dependency)).to be_falsey
      end

      it "returns false if the dependency matches the specified type and pattern but is excluded" do
        expect(dependency_group.contains?(test_dependency2)).to be_falsey
      end
    end
  end

  describe "#ignored_versions_for with experimental rules enabled" do
    let(:dependency) do
      Dependabot::Dependency.new(
        name: "business",
        package_manager: "bundler",
        version: "1.8.0",
        requirements: [
          { file: "Gemfile", requirement: "~> 1.8.0", groups: [], source: nil }
        ]
      )
    end

    before do
      Dependabot::Experiments.register(:grouped_updates_experimental_rules, true)
    end

    after do
      Dependabot::Experiments.reset!
    end

    context "the group has not defined a highest-semver-allowed rule" do
      it "ignores major versions by default" do
        expect(dependency_group.ignored_versions_for(dependency)).to eql([
          ">= 2.a"
        ])
      end
    end

    context "the group permits major or lower" do
      let(:rules) do
        {
          "highest-semver-allowed" => "major"
        }
      end

      it "returns an empty array as nothing should be ignored" do
        expect(dependency_group.ignored_versions_for(dependency)).to be_empty
      end
    end

    context "the group permits minor or lower" do
      let(:rules) do
        {
          "highest-semver-allowed" => "minor"
        }
      end

      it "returns a range which ignores major versions" do
        expect(dependency_group.ignored_versions_for(dependency)).to eql([
          ">= 2.a"
        ])
      end
    end

    context "when the group only permits patch versions" do
      let(:rules) do
        {
          "highest-semver-allowed" => "patch"
        }
      end

      it "returns ranges which ignore major and minor updates" do
        expect(dependency_group.ignored_versions_for(dependency)).to eql([
          ">= 2.a",
          ">= 1.9.a, < 2"
        ])
      end
    end

    context "when the group has garbage update-types" do
      let(:rules) do
        {
          "highest-semver-allowed" => "revision"
        }
      end

      it "raises an exception when created" do
        expect { dependency_group }.
          to raise_error(
            ArgumentError,
            starting_with("The #{name} group has an unexpected value for highest-semver-allowed:")
          )
      end
    end
  end

  describe "#ignored_versions_for with experimental rules disabled" do
    let(:dependency) do
      Dependabot::Dependency.new(
        name: "business",
        package_manager: "bundler",
        version: "1.8.0",
        requirements: [
          { file: "Gemfile", requirement: "~> 1.8.0", groups: [], source: nil }
        ]
      )
    end

    context "the group has not defined a highest-semver-allowed rule" do
      it "returns an empty array as nothing should be ignored" do
        expect(dependency_group.ignored_versions_for(dependency)).to be_empty
      end
    end

    context "the group has defined a highest-semver-allowed rule" do
      let(:rules) do
        {
          "highest-semver-allowed" => "patch"
        }
      end

      it "returns an empty array as nothing should be ignored" do
        expect(dependency_group.ignored_versions_for(dependency)).to be_empty
      end
    end
  end

  describe "#targets_highest_versions_possible with experimental rules enabled" do
    before do
      Dependabot::Experiments.register(:grouped_updates_experimental_rules, true)
    end

    after do
      Dependabot::Experiments.reset!
    end

    it "is false by default" do
      expect(dependency_group).not_to be_targets_highest_versions_possible
    end

    context "when the highest level is major" do
      let(:rules) do
        {
          "highest-semver-allowed" => "major"
        }
      end

      it "is true" do
        expect(dependency_group).to be_targets_highest_versions_possible
      end
    end

    context "when the highest level is minor" do
      let(:rules) do
        {
          "highest-semver-allowed" => "minor"
        }
      end

      it "is false" do
        expect(dependency_group).not_to be_targets_highest_versions_possible
      end
    end

    context "when the highest level is patch" do
      let(:rules) do
        {
          "highest-semver-allowed" => "patch"
        }
      end

      it "is false" do
        expect(dependency_group).not_to be_targets_highest_versions_possible
      end
    end
  end

  describe "#targets_highest_versions_possible with experimental rules enabled" do
    it "is true by default" do
      expect(dependency_group).to be_targets_highest_versions_possible
    end

    context "when the highest level is major" do
      let(:rules) do
        {
          "highest-semver-allowed" => "major"
        }
      end

      it "is true" do
        expect(dependency_group).to be_targets_highest_versions_possible
      end
    end

    context "when the highest level is minor" do
      let(:rules) do
        {
          "highest-semver-allowed" => "minor"
        }
      end

      it "is true" do
        expect(dependency_group).to be_targets_highest_versions_possible
      end
    end

    context "when the highest level is patch" do
      let(:rules) do
        {
          "highest-semver-allowed" => "patch"
        }
      end

      it "is true" do
        expect(dependency_group).to be_targets_highest_versions_possible
      end
    end
  end

  describe "#to_config_yaml" do
    let(:rules) do
      {
        "patterns" => ["test-*", "nothing-matches-this"],
        "exclude-patterns" => ["*-2"]
      }
    end

    it "renders the group to match our configuration file" do
      expect(dependency_group.to_config_yaml).to eql(<<~YAML)
        groups:
          test_group:
            patterns:
            - test-*
            - nothing-matches-this
            exclude-patterns:
            - "*-2"
      YAML
    end
  end
end

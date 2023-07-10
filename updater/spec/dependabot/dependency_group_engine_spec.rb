# frozen_string_literal: true

require "spec_helper"
require "support/dependency_file_helpers"

require "dependabot/dependency_group_engine"
require "dependabot/dependency_snapshot"
require "dependabot/job"

RSpec.describe Dependabot::DependencyGroupEngine do
  include DependencyFileHelpers

  let(:dependency_group_engine) { described_class.from_job_config(job: job) }

  let(:job) do
    instance_double(Dependabot::Job, dependency_groups: dependency_groups_config)
  end

  context "when a job has groups configured" do
    let(:dependency_groups_config) do
      [
        {
          "name" => "group-a",
          "rules" => {
            "patterns" => ["dummy-pkg-*"],
            "exclude-patterns" => ["dummy-pkg-b"]
          }
        },
        {
          "name" => "group-b",
          "rules" => {
            "patterns" => %w(dummy-pkg-b dummy-pkg-c)
          }
        }
      ]
    end

    describe "::from_job_config" do
      it "registers the dependency groups" do
        expect(dependency_group_engine.dependency_groups.length).to eql(2)
        expect(dependency_group_engine.dependency_groups.map(&:name)).to eql(%w(group-a group-b))
        expect(dependency_group_engine.dependency_groups.map(&:dependencies)).to all(be_empty)
      end
    end

    describe "#find_group" do
      it "retrieves a defined group by name" do
        group_a = dependency_group_engine.find_group(name: "group-a")
        expect(group_a.rules).to eql({
          "patterns" => ["dummy-pkg-*"],
          "exclude-patterns" => ["dummy-pkg-b"]
        })
      end

      it "returns nil if the group does not exist" do
        expect(dependency_group_engine.find_group(name: "no-such-thing")).to be_nil
      end
    end

    describe "#assign_to_groups!" do
      let(:dummy_pkg_a) do
        Dependabot::Dependency.new(
          name: "dummy-pkg-a",
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

      let(:dummy_pkg_b) do
        Dependabot::Dependency.new(
          name: "dummy-pkg-b",
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

      let(:dummy_pkg_c) do
        Dependabot::Dependency.new(
          name: "dummy-pkg-c",
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

      let(:ungrouped_pkg) do
        Dependabot::Dependency.new(
          name: "ungrouped_pkg",
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

      let(:dependencies) { [dummy_pkg_a, dummy_pkg_b, dummy_pkg_c, ungrouped_pkg] }

      before do
        dependency_group_engine.assign_to_groups!(dependencies: dependencies)
      end

      it "adds dependencies to every group they match" do
        group_a = dependency_group_engine.find_group(name: "group-a")
        expect(group_a.dependencies).to eql([dummy_pkg_a, dummy_pkg_c])

        group_b = dependency_group_engine.find_group(name: "group-b")
        expect(group_b.dependencies).to eql([dummy_pkg_b, dummy_pkg_c])
      end

      it "keeps a list of any dependencies that do not match any groups" do
        expect(dependency_group_engine.ungrouped_dependencies).to eql([ungrouped_pkg])
      end

      it "raises an exception if it is called a second time" do
        expect { dependency_group_engine.assign_to_groups!(dependencies: dependencies) }.
          to raise_error(described_class::ConfigurationError, "dependency groups have already been configured!")
      end
    end
  end
end

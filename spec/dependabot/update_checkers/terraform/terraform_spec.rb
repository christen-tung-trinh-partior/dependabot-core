# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/update_checkers/terraform/terraform"
require_relative "../shared_examples_for_update_checkers"

RSpec.describe Dependabot::UpdateCheckers::Terraform::Terraform do
  it_behaves_like "an update checker"

  let(:checker) do
    described_class.new(
      dependency: dependency,
      dependency_files: [],
      credentials: credentials
    )
  end
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: version,
      requirements: requirements,
      package_manager: "terraform"
    )
  end
  let(:dependency_name) { "origin_label" }
  let(:version) { nil }
  let(:requirements) do
    [{ requirement: nil, groups: [], file: "main.tf", source: source }]
  end
  let(:source) do
    {
      type: "git",
      url: "https://github.com/cloudposse/terraform-null-label.git",
      branch: nil,
      ref: "tags/0.3.7"
    }
  end

  describe "#latest_version" do
    subject { checker.latest_version }

    context "with a git dependency" do
      let(:source) do
        {
          type: "git",
          url: "https://github.com/cloudposse/terraform-null-label.git",
          branch: nil,
          ref: "tags/0.3.7"
        }
      end

      before do
        git_url = "https://github.com/cloudposse/terraform-null-label.git"
        git_header = {
          "content-type" => "application/x-git-upload-pack-advertisement"
        }
        stub_request(:get, git_url + "/info/refs?service=git-upload-pack").
          to_return(
            status: 200,
            body: fixture("git", "upload_packs", "terraform-null-label"),
            headers: git_header
          )
      end

      it { is_expected.to eq("tags/0.4.1") }
    end
  end

  describe "#latest_resolvable_version" do
    subject { checker.latest_resolvable_version }

    context "with a git dependency" do
      let(:source) do
        {
          type: "git",
          url: "https://github.com/cloudposse/terraform-null-label.git",
          branch: nil,
          ref: "tags/0.3.7"
        }
      end

      before do
        allow(checker).to receive(:latest_version).and_return("delegated")
      end

      it { is_expected.to eq("delegated") }
    end
  end

  describe "#updated_requirements" do
    subject(:updated_requirements) { checker.updated_requirements }

    context "with a git dependency" do
      let(:source) do
        {
          type: "git",
          url: "https://github.com/cloudposse/terraform-null-label.git",
          branch: nil,
          ref: ref
        }
      end
      let(:ref) { "tags/0.3.7" }

      before { allow(checker).to receive(:latest_version).and_return(latest) }
      let(:latest) { "delegated" }

      context "with a reference" do
        let(:ref) { "tags/0.3.7" }

        it "updates the reference" do
          expect(updated_requirements).
            to eq(
              [{
                requirement: nil,
                groups: [],
                file: "main.tf",
                source: {
                  type: "git",
                  url: "https://github.com/cloudposse/terraform-null-label.git",
                  branch: nil,
                  ref: "delegated"
                }
              }]
            )
        end
      end

      context "without a reference" do
        let(:ref) { nil }
        it { is_expected.to eq(requirements) }
      end

      context "without a latest version" do
        let(:latest) { nil }
        it { is_expected.to eq(requirements) }
      end

      context "without a git SHA as the latest version" do
        let(:latest) { "a" * 40 }
        it { is_expected.to eq(requirements) }
      end
    end
  end
end

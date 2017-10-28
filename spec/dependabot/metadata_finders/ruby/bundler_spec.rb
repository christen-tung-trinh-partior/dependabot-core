# frozen_string_literal: true

require "octokit"
require "spec_helper"
require "dependabot/dependency"
require "dependabot/metadata_finders/ruby/bundler"
require_relative "../shared_examples_for_metadata_finders"

RSpec.describe Dependabot::MetadataFinders::Ruby::Bundler do
  it_behaves_like "a dependency metadata finder"

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: "1.0",
      requirements: [
        { file: "Gemfile", requirement: ">= 0", groups: [], source: nil }
      ],
      previous_requirements: [
        { file: "Gemfile", requirement: ">= 0", groups: [], source: nil }
      ],
      package_manager: "bundler"
    )
  end
  subject(:finder) do
    described_class.new(dependency: dependency, github_client: github_client)
  end
  let(:github_client) { Octokit::Client.new(access_token: "token") }
  let(:dependency_name) { "business" }

  describe "#source_url" do
    subject(:source_url) { finder.source_url }

    context "for a non-default rubygems source" do
      let(:dependency) do
        Dependabot::Dependency.new(
          name: dependency_name,
          version: "1.0",
          requirements: [
            {
              file: "Gemfile",
              requirement: ">= 0",
              groups: [],
              source: { type: "rubygems" }
            }
          ],
          package_manager: "bundler"
        )
      end

      it { is_expected.to eq(nil) }
    end

    context "for a git source" do
      let(:dependency) do
        Dependabot::Dependency.new(
          name: dependency_name,
          version: "1.0",
          requirements: [
            {
              file: "Gemfile",
              requirement: ">= 0",
              groups: [],
              source: {
                type: "git",
                url: "https://github.com/my_fork/business"
              }
            }
          ],
          package_manager: "bundler"
        )
      end

      it { is_expected.to eq("https://github.com/my_fork/business") }

      context "that doesn't match a supported source" do
        let(:dependency) do
          Dependabot::Dependency.new(
            name: dependency_name,
            version: "1.0",
            requirements: [
              {
                file: "Gemfile",
                requirement: ">= 0",
                groups: [],
                source: {
                  type: "git",
                  url: "https://example.com/my_fork/business"
                }
              }
            ],
            package_manager: "bundler"
          )
        end

        it { is_expected.to be_nil }
      end

      context "that is overriding a gemspec source" do
        let(:dependency) do
          Dependabot::Dependency.new(
            name: dependency_name,
            version: "1.0",
            requirements: [
              {
                file: "Gemfile",
                requirement: ">= 0",
                groups: [],
                source: {
                  type: "git",
                  url: "https://github.com/my_fork/business"
                }
              },
              {
                file: "example.gemspec",
                requirement: ">= 0",
                groups: [],
                source: nil
              }
            ],
            package_manager: "bundler"
          )
        end

        it { is_expected.to eq("https://github.com/my_fork/business") }
      end
    end

    context "for a default source" do
      let(:rubygems_url) { "https://rubygems.org/api/v1/gems/business.json" }
      let(:rubygems_response_code) { 200 }
      before do
        stub_request(:get, rubygems_url).
          to_return(status: rubygems_response_code, body: rubygems_response)
      end

      context "when there is a github link in the rubygems response" do
        let(:rubygems_response) { fixture("ruby", "rubygems_response.json") }

        it { is_expected.to eq("https://github.com/gocardless/business") }

        it "caches the call to rubygems" do
          2.times { source_url }
          expect(WebMock).to have_requested(:get, rubygems_url).once
        end

        context "that contains a .git suffix" do
          let(:rubygems_response) do
            fixture("ruby", "rubygems_response_period_github.json")
          end

          it { is_expected.to eq("https://github.com/gocardless/business.rb") }
        end
      end

      context "when there is a bitbucket link in the rubygems response" do
        let(:rubygems_response) do
          fixture("ruby", "rubygems_response_bitbucket.json")
        end

        it { is_expected.to eq("https://bitbucket.org/gocardless/business") }

        it "caches the call to rubygems" do
          2.times { source_url }
          expect(WebMock).to have_requested(:get, rubygems_url).once
        end
      end

      context "when there is a gitlab link in the rubygems response" do
        let(:rubygems_response) do
          fixture("ruby", "rubygems_response_gitlab.json")
        end

        it { is_expected.to eq("https://gitlab.com/zachdaniel/result-monad") }

        it "caches the call to rubygems" do
          2.times { source_url }
          expect(WebMock).to have_requested(:get, rubygems_url).once
        end
      end

      context "when there isn't a source link in the rubygems response" do
        let(:rubygems_response) do
          fixture("ruby", "rubygems_response_no_source.json")
        end

        it { is_expected.to be_nil }

        it "caches the call to rubygems" do
          2.times { source_url }
          expect(WebMock).to have_requested(:get, rubygems_url).once
        end
      end

      context "when the gem isn't on Rubygems" do
        let(:rubygems_response_code) { 404 }
        let(:rubygems_response) { "This rubygem could not be found." }

        it { is_expected.to be_nil }
      end
    end
  end

  describe "#changelog_url" do
    subject(:changelog_url) { finder.changelog_url }
    let(:rubygems_url) { "https://rubygems.org/api/v1/gems/business.json" }
    let(:rubygems_response_code) { 200 }

    before do
      stub_request(:get, rubygems_url).
        to_return(status: rubygems_response_code, body: rubygems_response)
    end

    context "when there is a changelog link in the rubygems response" do
      let(:rubygems_response) do
        fixture("ruby", "rubygems_response_changelog.json")
      end

      it "returns the specified changelog" do
        expect(changelog_url).
          to eq("https://github.com/rails/rails/tree/v5.1.3/activejob")
      end
    end

    context "when there is only a github link in the rubygems response" do
      let(:rubygems_response) { fixture("ruby", "rubygems_response.json") }
      let(:github_url) do
        "https://api.github.com/repos/gocardless/business/contents/"
      end

      before do
        stub_request(:get, github_url).
          to_return(status: 200,
                    body: fixture("github", "business_files.json"),
                    headers: { "Content-Type" => "application/json" })
      end

      it "finds the changelog as normal" do
        expect(changelog_url).
          to eq(
            "https://github.com/gocardless/business/blob/master/CHANGELOG.md"
          )
      end
    end

    context "for a git dependency" do
      let(:rubygems_response) { nil }
      let(:dependency) do
        Dependabot::Dependency.new(
          name: dependency_name,
          version: "1.0",
          requirements: [
            {
              file: "Gemfile",
              requirement: ">= 0",
              groups: [],
              source: {
                type: "git",
                url: "https://github.com/gocardless/business",
                ref: new_ref
              }
            }
          ],
          previous_requirements: [
            {
              file: "Gemfile",
              requirement: ">= 0",
              groups: [],
              source: {
                type: "git",
                url: "https://github.com/gocardless/business",
                ref: old_ref
              }
            }
          ],
          package_manager: "bundler"
        )
      end
      let(:new_ref) { "master" }
      let(:old_ref) { "master" }

      it { is_expected.to be_nil }

      context "when the ref has changed" do
        let(:new_ref) { "v1.1.0" }
        let(:old_ref) { "v1.0.0" }

        let(:github_url) do
          "https://api.github.com/repos/gocardless/business/contents/"
        end

        before do
          stub_request(:get, github_url).
            to_return(status: 200,
                      body: fixture("github", "business_files.json"),
                      headers: { "Content-Type" => "application/json" })
        end

        it "finds the changelog as normal" do
          expect(changelog_url).
            to eq(
              "https://github.com/gocardless/business/blob/master/CHANGELOG.md"
            )
        end
      end
    end
  end

  describe "#commits_url" do
    subject(:commits_url) { finder.commits_url }

    context "with a git source" do
      let(:dependency) do
        Dependabot::Dependency.new(
          name: "business",
          version: "cd8274d15fa3ae2ab983129fb037999f264ba9a7",
          previous_version: previous_version,
          requirements: [
            {
              file: "Gemfile",
              requirement: ">= 0",
              groups: [],
              source: {
                type: "git",
                url: "https://github.com/gocardless/business"
              }
            }
          ],
          previous_requirements: [
            {
              file: "Gemfile",
              requirement: ">= 0",
              groups: [],
              source: {
                type: "git",
                url: "https://github.com/gocardless/business"
              }
            }
          ],
          package_manager: "bundler"
        )
      end
      let(:previous_version) { "7638417db6d59f3c431d3e1f261cc637155684cd" }

      it "uses the SHA-1 hashes to build the compare URL" do
        expect(commits_url).
          to eq(
            "https://github.com/gocardless/business/compare/"\
            "7638417db6d59f3c431d3e1f261cc637155684cd..."\
            "cd8274d15fa3ae2ab983129fb037999f264ba9a7"
          )
      end

      context "with a non-github source" do
        let(:dependency) do
          Dependabot::Dependency.new(
            name: "business",
            version: "cd8274d15fa3ae2ab983129fb037999f264ba9a7",
            previous_version: previous_version,
            requirements: [
              {
                file: "Gemfile",
                requirement: ">= 0",
                groups: [],
                source: {
                  type: "git",
                  url: "https://example.com/gocardless/business"
                }
              }
            ],
            previous_requirements: [
              {
                file: "Gemfile",
                requirement: ">= 0",
                groups: [],
                source: {
                  type: "git",
                  url: "https://example.com/gocardless/business"
                }
              }
            ],
            package_manager: "bundler"
          )
        end

        it { is_expected.to be_nil }
      end

      context "without a previous version" do
        let(:previous_version) { nil }
        let(:rubygems_response) { fixture("ruby", "rubygems_response.json") }
        let(:rubygems_url) { "https://rubygems.org/api/v1/gems/business.json" }

        before do
          stub_request(:get, rubygems_url).
            to_return(status: 200, body: rubygems_response)
          stub_request(
            :get,
            "https://api.github.com/repos/gocardless/business/tags?per_page=100"
          ).to_return(
            status: 200,
            body: fixture("github", "business_tags.json"),
            headers: { "Content-Type" => "application/json" }
          )
        end

        it "finds the commits as normal" do
          expect(commits_url).
            to eq("https://github.com/gocardless/business/commits/"\
                  "cd8274d15fa3ae2ab983129fb037999f264ba9a7")
        end
      end
    end

    context "with the default Rubygems source" do
      let(:rubygems_response) { fixture("ruby", "rubygems_response.json") }
      let(:rubygems_url) { "https://rubygems.org/api/v1/gems/business.json" }

      before do
        stub_request(:get, rubygems_url).
          to_return(status: 200, body: rubygems_response)
        stub_request(
          :get,
          "https://api.github.com/repos/gocardless/business/tags?per_page=100"
        ).to_return(
          status: 200,
          body: fixture("github", "business_tags.json"),
          headers: { "Content-Type" => "application/json" }
        )
      end

      it "finds the commits as normal" do
        expect(commits_url).
          to eq("https://github.com/gocardless/business/commits")
      end

      context "when the dependency previously had a git source" do
        let(:dependency) do
          Dependabot::Dependency.new(
            name: "business",
            version: "1.5.0",
            previous_version: previous_version,
            requirements: [
              { file: "Gemfile", requirement: ">= 0", groups: [], source: nil }
            ],
            previous_requirements: [
              {
                file: "Gemfile",
                requirement: ">= 0",
                groups: [],
                source: {
                  type: "git",
                  url: "https://github.com/gocardless/business",
                  branch: "master",
                  ref: "7638417d"
                }
              }
            ],
            package_manager: "bundler"
          )
        end
        let(:previous_version) { "7638417db6d59f3c431d3e1f261cc637155684cd" }
        let(:rubygems_response) { fixture("ruby", "rubygems_response.json") }
        let(:rubygems_url) { "https://rubygems.org/api/v1/gems/business.json" }

        before do
          stub_request(:get, rubygems_url).
            to_return(status: 200, body: rubygems_response)
          stub_request(
            :get,
            "https://api.github.com/repos/gocardless/business/tags?per_page=100"
          ).to_return(
            status: 200,
            body: fixture("github", "business_tags.json"),
            headers: { "Content-Type" => "application/json" }
          )
        end

        it "uses the SHA-1 hash previous version to build the compare URL" do
          expect(commits_url).
            to eq(
              "https://github.com/gocardless/business/compare/"\
              "7638417db6d59f3c431d3e1f261cc637155684cd...v1.5.0"
            )
        end

        context "without a previous version" do
          let(:previous_version) { nil }

          it "uses the reference specified" do
            expect(commits_url).
              to eq("https://github.com/gocardless/business/compare/"\
                    "7638417d...v1.5.0")
          end
        end
      end
    end
  end
end

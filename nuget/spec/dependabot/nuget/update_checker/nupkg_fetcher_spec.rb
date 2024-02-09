# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/nuget/update_checker/nupkg_fetcher"
require "dependabot/nuget/update_checker/repository_finder"

RSpec.describe Dependabot::Nuget::NupkgFetcher do
  describe "#fetch_nupkg_url_from_repository" do
    let(:dependency) { Dependabot::Dependency.new(name: package_name, requirements: [], package_manager: "nuget") }
    let(:package_name) { "Newtonsoft.Json" }
    let(:package_version) { "13.0.1" }
    let(:credentials) { [] }
    let(:config_files) { [nuget_config] }
    let(:nuget_config) do
      Dependabot::DependencyFile.new(
        name: "NuGet.config",
        content: nuget_config_content
      )
    end
    let(:nuget_config_content) do
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <configuration>
          <packageSources>
            <clear />
            <add key="test-source" value="#{feed_url}" />
          </packageSources>
        </configuration>
      XML
    end
    let(:repository_finder) do
      Dependabot::Nuget::RepositoryFinder.new(dependency: dependency, credentials: credentials,
                                              config_files: config_files)
    end
    let(:repository_details) { repository_finder.dependency_urls.first }
    subject(:nupkg_url) do
      described_class.fetch_nupkg_url_from_repository(repository_details, package_name, package_version)
    end

    context "with a nuget feed url" do
      let(:feed_url) { "https://api.nuget.org/v3/index.json" }

      before do
        stub_request(:get, feed_url)
          .to_return(
            status: 200,
            body: fixture("nuget_responses", "index.json", "nuget.index.json")
          )
      end

      it { is_expected.to eq("https://api.nuget.org/v3-flatcontainer/newtonsoft.json/13.0.1/newtonsoft.json.13.0.1.nupkg") }
    end

    context "with an azure feed url" do
      let(:feed_url) { "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json" }

      before do
        stub_request(:get, feed_url)
          .to_return(
            status: 200,
            body: fixture("nuget_responses", "index.json", "dotnet-public.index.json")
          )
      end

      it { is_expected.to eq("https://pkgs.dev.azure.com/dnceng/9ee6d478-d288-47f7-aacc-f6e6d082ae6d/_packaging/45bacae2-5efb-47c8-91e5-8ec20c22b4f8/nuget/v3/flat2/newtonsoft.json/13.0.1/newtonsoft.json.13.0.1.nupkg") }
    end

    context "with a github feed url" do
      let(:feed_url) { "https://nuget.pkg.github.com/some-namespace/index.json" }

      before do
        stub_request(:get, feed_url)
          .to_return(
            status: 200,
            body: fixture("nuget_responses", "index.json", "github.index.json")
          )
      end

      it { is_expected.to eq("https://nuget.pkg.github.com/some-namespace/download/newtonsoft.json/13.0.1/newtonsoft.json.13.0.1.nupkg") }
    end
  end

  describe "#fetch_nupkg_buffer" do
    let(:package_id) { "Newtonsoft.Json" }
    let(:package_version) { "13.0.1" }
    let(:repository_details) { Dependabot::Nuget::RepositoryFinder.get_default_repository_details(package_id) }
    let(:dependency_urls) { [repository_details] }
    subject(:nupkg_buffer) do
      described_class.fetch_nupkg_buffer(dependency_urls, package_id, package_version)
    end

    before do
      stub_request(:get, "https://api.nuget.org/v3-flatcontainer/newtonsoft.json/13.0.1/newtonsoft.json.13.0.1.nupkg")
        .to_return(
          status: 303,
          headers: {
            "Location" => "https://api.nuget.org/redirect-on-303"
          },
          body: "not the final contents"
        )
      stub_request(:get, "https://api.nuget.org/redirect-on-303")
        .to_return(
          status: 307,
          headers: {
            "Location" => "https://api.nuget.org/redirect-on-307"
          },
          body: "almost final contents"
        )
      stub_request(:get, "https://api.nuget.org/redirect-on-307")
        .to_return(
          status: 200,
          body: "the final contents"
        )
    end

    it "fetches the nupkg after multiple redirects" do
      expect(nupkg_buffer.string).to eq("the final contents")
    end
  end
end

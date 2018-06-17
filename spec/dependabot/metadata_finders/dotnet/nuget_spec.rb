# frozen_string_literal: true

require "dependabot/dependency"
require "dependabot/metadata_finders/dotnet/nuget"
require_relative "../shared_examples_for_metadata_finders"

RSpec.describe Dependabot::MetadataFinders::Dotnet::Nuget do
  it_behaves_like "a dependency metadata finder"

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      requirements: [{
        file: "my.csproj",
        requirement: dependency_version,
        groups: [],
        source: nil
      }],
      package_manager: "nuget"
    )
  end
  subject(:finder) do
    described_class.new(dependency: dependency, credentials: credentials)
  end
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end
  let(:dependency_name) { "Microsoft.Extensions.DependencyModel" }
  let(:dependency_version) { "2.1.0" }

  describe "#source_url" do
    subject(:source_url) { finder.source_url }
    let(:nuget_url) do
      "https://api.nuget.org/v3-flatcontainer/"\
      "microsoft.extensions.dependencymodel/2.1.0/"\
      "microsoft.extensions.dependencymodel.nuspec"
    end
    let(:nuget_response) do
      fixture(
        "dotnet",
        "nuspecs",
        "Microsoft.Extensions.DependencyModel.nuspec"
      )
    end

    before do
      stub_request(:get, nuget_url).to_return(status: 200, body: nuget_response)
    end

    context "with a github link in the pom" do
      it { is_expected.to eq("https://github.com/dotnet/core-setup") }

      it "caches the call to nuget" do
        2.times { source_url }
        expect(WebMock).to have_requested(:get, nuget_url).once
      end
    end
  end
end

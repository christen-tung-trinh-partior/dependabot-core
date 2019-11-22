# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/maven/update_checker/version_finder"

RSpec.describe Dependabot::Maven::UpdateChecker::VersionFinder do
  let(:finder) do
    described_class.new(
      dependency: dependency,
      dependency_files: dependency_files,
      credentials: credentials,
      ignored_versions: ignored_versions,
      security_advisories: security_advisories
    )
  end
  let(:version_class) { Dependabot::Maven::Version }
  let(:credentials) { [] }
  let(:ignored_versions) { [] }
  let(:security_advisories) { [] }

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      requirements: dependency_requirements,
      package_manager: "maven"
    )
  end
  let(:dependency_files) { [pom] }
  let(:pom) do
    Dependabot::DependencyFile.new(
      name: "pom.xml",
      content: fixture("poms", pom_fixture_name)
    )
  end
  let(:pom_fixture_name) { "basic_pom.xml" }

  let(:dependency_requirements) do
    [{
      file: "pom.xml",
      requirement: dependency_version,
      groups: [],
      source: nil,
      metadata: { packaging_type: "jar" }
    }]
  end
  let(:dependency_name) { "com.google.guava:guava" }
  let(:dependency_version) { "23.3-jre" }

  let(:maven_central_metadata_url) do
    "https://repo.maven.apache.org/maven2/"\
    "com/google/guava/guava/maven-metadata.xml"
  end
  let(:maven_central_releases) do
    fixture("maven_central_metadata", "with_release.xml")
  end
  let(:maven_central_version_files_url) do
    "https://repo.maven.apache.org/maven2/"\
    "com/google/guava/guava/23.6-jre/guava-23.6-jre.jar"
  end

  before do
    stub_request(:get, maven_central_metadata_url).
      to_return(status: 200, body: maven_central_releases)
    stub_request(:head, maven_central_version_files_url).
      to_return(status: 200)
  end

  describe "#latest_version_details" do
    subject { finder.latest_version_details }
    its([:version]) { is_expected.to eq(version_class.new("23.6-jre")) }
    its([:source_url]) do
      is_expected.to eq("https://repo.maven.apache.org/maven2")
    end

    context "when the latest version hasn't actually been released" do
      let(:maven_central_version_files_url) do
        "https://repo.maven.apache.org/maven2/"\
        "com/google/guava/guava/23.6-jre/guava-23.6-jre.jar"
      end
      let(:old_maven_central_version_files_url) do
        "https://repo.maven.apache.org/maven2/"\
        "com/google/guava/guava/23.5-jre/guava-23.5-jre.jar"
      end

      before do
        stub_request(:head, maven_central_version_files_url).
          to_return(status: 404)
        stub_request(:head, old_maven_central_version_files_url).
          to_return(status: 200)
      end

      its([:version]) { is_expected.to eq(version_class.new("23.5-jre")) }
    end

    context "when the user wants a pre-release" do
      let(:dependency_version) { "23.0-rc1-android" }
      let(:maven_central_version_files_url) do
        "https://repo.maven.apache.org/maven2/"\
        "com/google/guava/guava/23.7-rc1-android/guava-23.7-rc1-android.jar"
      end
      let(:maven_central_version_files) do
        fixture("maven_central_version_files", "guava-23.7.html")
      end
      its([:version]) do
        is_expected.to eq(version_class.new("23.7-rc1-android"))
      end
    end

    context "when there are date-based versions" do
      let(:dependency_version) { "3.1" }
      let(:dependency_name) { "commons-collections:commons-collections" }

      let(:maven_central_metadata_url) do
        "https://repo.maven.apache.org/maven2/"\
        "commons-collections/commons-collections/maven-metadata.xml"
      end
      let(:maven_central_version_files_url) do
        "https://repo.maven.apache.org/maven2/"\
        "commons-collections/commons-collections/3.2.2/"\
        "commons-collections-3.2.2.jar"
      end
      let(:maven_central_releases) do
        fixture("maven_central_metadata", "with_date_releases.xml")
      end
      let(:maven_central_version_files) do
        fixture(
          "maven_central_version_files",
          "commons-collections-3.2.2.html"
        )
      end

      its([:version]) { is_expected.to eq(version_class.new("3.2.2")) }

      context "and that's what we're using" do
        let(:dependency_version) { "20030418" }
        let(:maven_central_version_files_url) do
          "https://repo.maven.apache.org/maven2/"\
          "commons-collections/commons-collections/20040616/"\
          "commons-collections-20040616.jar"
        end
        let(:maven_central_version_files) do
          fixture(
            "maven_central_version_files",
            "commons-collections-20040616.html"
          )
        end
        its([:version]) { is_expected.to eq(version_class.new("20040616")) }
      end
    end

    context "when the user has asked to ignore a major version" do
      let(:ignored_versions) { [">= 23.0, < 24"] }
      let(:dependency_version) { "17.0" }
      let(:maven_central_version_files_url) do
        "https://repo.maven.apache.org/maven2/"\
        "com/google/guava/guava/22.0/guava-22.0.jar"
      end
      let(:maven_central_version_files) do
        fixture("maven_central_version_files", "guava-22.0.html")
      end
      its([:version]) { is_expected.to eq(version_class.new("22.0")) }
    end

    context "when the current version isn't normal" do
      let(:dependency_version) { "RELEASE802" }
      let(:maven_central_version_files_url) do
        "https://repo.maven.apache.org/maven2/"\
        "com/google/guava/guava/23.0/guava-23.0.jar"
      end
      let(:maven_central_version_files) do
        fixture("maven_central_version_files", "guava-23.0.html")
      end
      its([:version]) { is_expected.to eq(version_class.new("23.0")) }
    end

    context "with a repository from credentials" do
      let(:credentials) do
        [{
          "type" => "maven_repository",
          "url" => "https://private.registry.org/repo/",
          "username" => "dependabot",
          "password" => "dependabotPassword"
        }]
      end

      let(:private_registry_metadata_url) do
        "https://private.registry.org/repo/"\
        "com/google/guava/guava/maven-metadata.xml"
      end

      before do
        stub_request(:get, maven_central_metadata_url).
          to_return(status: 404)
        stub_request(:get, private_registry_metadata_url).
          with(basic_auth: %w(dependabot dependabotPassword)).
          to_return(status: 200, body: maven_central_releases)
      end

      its([:version]) { is_expected.to eq(version_class.new("23.6-jre")) }
      its([:source_url]) do
        is_expected.to eq("https://private.registry.org/repo")
      end

      context "but no auth details" do
        let(:credentials) do
          [{
            "type" => "maven_repository",
            "url" => "https://private.registry.org/repo/"
          }]
        end

        before do
          stub_request(:get, private_registry_metadata_url).
            to_return(status: 200, body: maven_central_releases)
        end

        its([:version]) { is_expected.to eq(version_class.new("23.6-jre")) }
        its([:source_url]) do
          is_expected.to eq("https://private.registry.org/repo")
        end

        context "when credentials are required" do
          before do
            stub_request(:get, private_registry_metadata_url).
              to_return(status: 401, body: "no dice")
          end

          it "raises a helpful error" do
            error_class = Dependabot::PrivateSourceAuthenticationFailure
            expect { subject }.
              to raise_error(error_class) do |error|
                expect(error.source).to eq("https://private.registry.org/repo")
              end
          end
        end
      end
    end

    context "with a custom repository" do
      let(:pom_fixture_name) { "custom_repositories_pom.xml" }

      let(:scala_tools_metadata_url) do
        "http://scala-tools.org/repo-releases/"\
        "com/google/guava/guava/maven-metadata.xml"
      end

      let(:scala_tools_version_files_url) do
        "http://scala-tools.org/repo-releases/"\
        "com/google/guava/guava/23.6-jre/guava-23.6-jre.jar"
      end

      let(:jboss_metadata_url) do
        "http://repository.jboss.org/maven2/"\
        "com/google/guava/guava/maven-metadata.xml"
      end

      let(:jboss_plugins_metadata_url) do
        "http://plugin-repository.jboss.org/maven2/"\
        "com/google/guava/guava/maven-metadata.xml"
      end

      let(:jboss_plugins_version_files_url) do
        "http://plugin-repository.jboss.org/maven2/"\
        "com/google/guava/guava/23.6-jre/guava-23.6-jre.jar"
      end

      let(:jboss_version_files_url) do
        "http://repository.jboss.org/maven2/"\
        "com/google/guava/guava/23.6-jre/guava-23.6-jre.jar"
      end

      before do
        stub_request(:get, maven_central_metadata_url).
          to_return(status: 404, body: "")
        stub_request(:get, scala_tools_metadata_url).
          to_raise(Excon::Error::Timeout)
        stub_request(:get, jboss_metadata_url).
          to_return(
            status: 200,
            body: fixture("maven_central_metadata", "with_release.xml")
          )
        stub_request(:get, jboss_plugins_metadata_url).
          to_return(status: 404, body: "")
        stub_request(:head, maven_central_version_files_url).
          to_return(status: 404)
        stub_request(:head, scala_tools_version_files_url).
          to_return(status: 404)
        stub_request(:head, jboss_plugins_version_files_url).
          to_return(status: 404)
        stub_request(:head, jboss_version_files_url).
          to_return(status: 200)
      end

      its([:version]) { is_expected.to eq(version_class.new("23.6-jre")) }
      its([:source_url]) do
        is_expected.to eq("http://repository.jboss.org/maven2")
      end
    end
  end

  describe "#lowest_security_fix_version_details" do
    subject { finder.lowest_security_fix_version_details }

    let(:dependency_version) { "18.0" }
    let(:security_advisories) do
      [
        Dependabot::SecurityAdvisory.new(
          dependency_name: "rails",
          package_manager: "maven",
          safe_versions: ["> 19.0"]
        )
      ]
    end
    let(:maven_central_version_files_url) do
      "https://repo.maven.apache.org/maven2/"\
      "com/google/guava/guava/20.0/guava-20.0.jar"
    end
    let(:maven_central_version_files) do
      fixture("maven_central_version_files", "guava-23.6.html").
        gsub("23.6-jre", "20.0")
    end

    its([:version]) { is_expected.to eq(version_class.new("20.0")) }
    its([:source_url]) do
      is_expected.to eq("https://repo.maven.apache.org/maven2")
    end

    context "when the lowest version hasn't actually been released" do
      let(:maven_central_version_files_url) do
        "https://repo.maven.apache.org/maven2/"\
        "com/google/guava/guava/20.0/guava-20.0.jar"
      end
      let(:next_maven_central_version_files_url) do
        "https://repo.maven.apache.org/maven2/"\
        "com/google/guava/guava/21.0/guava-21.0.jar"
      end

      before do
        stub_request(:head, maven_central_version_files_url).
          to_return(status: 404)
        stub_request(:head, next_maven_central_version_files_url).
          to_return(status: 200)
      end

      its([:version]) { is_expected.to eq(version_class.new("21.0")) }
    end
  end

  describe "#versions" do
    subject(:versions) { finder.versions }
    its(:count) { is_expected.to eq(70) }

    describe "the first version" do
      subject { versions.first }

      its([:version]) { is_expected.to eq(version_class.new("r03")) }
      its([:source_url]) do
        is_expected.to eq("https://repo.maven.apache.org/maven2")
      end
    end

    describe "the last version" do
      subject { versions.last }

      its([:version]) { is_expected.to eq(version_class.new("23.7-rc1-jre")) }
      its([:source_url]) do
        is_expected.to eq("https://repo.maven.apache.org/maven2")
      end
    end

    context "with a dependency name that needs URI encoding" do
      let(:dependency_name) { "bad com.google.guava:guava" }

      its(:count) { is_expected.to eq(0) }
    end

    context "with a custom repository" do
      let(:pom_fixture_name) { "custom_repositories_pom.xml" }

      let(:scala_tools_metadata_url) do
        "http://scala-tools.org/repo-releases/"\
        "com/google/guava/guava/maven-metadata.xml"
      end

      let(:jboss_metadata_url) do
        "http://repository.jboss.org/maven2/"\
        "com/google/guava/guava/maven-metadata.xml"
      end

      let(:jboss_plugins_metadata_url) do
        "http://plugin-repository.jboss.org/maven2/"\
        "com/google/guava/guava/maven-metadata.xml"
      end

      before do
        stub_request(:get, maven_central_metadata_url).
          to_return(status: 404, body: "")
        stub_request(:get, scala_tools_metadata_url).
          to_return(status: 404, body: "")
        stub_request(:get, jboss_metadata_url).
          to_return(
            status: 200,
            body: fixture("maven_central_metadata", "with_release.xml")
          )
        stub_request(:get, jboss_plugins_metadata_url).
          to_return(status: 404, body: "")
      end

      describe "the first version" do
        subject { versions.first }

        its([:version]) { is_expected.to eq(version_class.new("r03")) }
        its([:source_url]) do
          is_expected.to eq("http://repository.jboss.org/maven2")
        end
      end

      describe "the last version" do
        subject { versions.last }

        its([:version]) { is_expected.to eq(version_class.new("23.7-rc1-jre")) }
        its([:source_url]) do
          is_expected.to eq("http://repository.jboss.org/maven2")
        end
      end

      context "that augment the central repo" do
        before do
          body =
            fixture("maven_central_metadata", "with_date_releases.xml")
          stub_request(:get, maven_central_metadata_url).
            to_return(status: 200, body: body)
        end

        its(:count) { is_expected.to eq(87) }

        describe "the first version" do
          subject { versions.first }

          its([:version]) { is_expected.to eq(version_class.new("r01")) }
          its([:source_url]) do
            is_expected.to eq("https://repo.maven.apache.org/maven2")
          end
        end

        describe "the last version" do
          subject { versions.last }

          its([:version]) { is_expected.to eq(version_class.new("20040616")) }
          its([:source_url]) do
            is_expected.to eq("https://repo.maven.apache.org/maven2")
          end
        end
      end
    end
  end
end

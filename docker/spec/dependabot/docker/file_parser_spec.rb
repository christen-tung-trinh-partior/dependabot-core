# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency_file"
require "dependabot/source"
require "dependabot/docker/file_parser"
require_common_spec "file_parsers/shared_examples_for_file_parsers"

RSpec.describe Dependabot::Docker::FileParser do
  it_behaves_like "a dependency file parser"

  let(:files) { [dockerfile] }
  let(:dockerfile) do
    Dependabot::DependencyFile.new(name: "Dockerfile", content: dockerfile_body)
  end
  let(:dockerfile_body) do
    fixture("docker", "dockerfiles", dockerfile_fixture_name)
  end
  let(:dockerfile_fixture_name) { "tag" }
  let(:parser) { described_class.new(dependency_files: files, source: source) }
  let(:source) do
    Dependabot::Source.new(
      provider: "github",
      repo: "gocardless/bump",
      directory: "/"
    )
  end

  describe "parse" do
    subject(:dependencies) { parser.parse }

    its(:length) { is_expected.to eq(1) }

    describe "the first dependency" do
      subject(:dependency) { dependencies.first }
      let(:expected_requirements) do
        [{
          requirement: nil,
          groups: [],
          file: "Dockerfile",
          source: { tag: "17.04" }
        }]
      end

      it "has the right details" do
        expect(dependency).to be_a(Dependabot::Dependency)
        expect(dependency.name).to eq("ubuntu")
        expect(dependency.version).to eq("17.04")
        expect(dependency.requirements).to eq(expected_requirements)
      end
    end

    context "with no tag or digest" do
      let(:dockerfile_fixture_name) { "bare" }
      its(:length) { is_expected.to eq(0) }
    end

    context "with a name" do
      let(:dockerfile_fixture_name) { "name" }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: { tag: "17.04" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("ubuntu")
          expect(dependency.version).to eq("17.04")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end
    end

    context "with a namespace" do
      let(:dockerfile_fixture_name) { "namespace" }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: { tag: "17.04" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("my-fork/ubuntu")
          expect(dependency.version).to eq("17.04")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end
    end

    context "with a FROM line written by a nutcase" do
      let(:dockerfile_fixture_name) { "case" }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: { tag: "17.04" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("ubuntu")
          expect(dependency.version).to eq("17.04")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end
    end

    context "with a non-numeric version" do
      let(:dockerfile_body) { "FROM ubuntu:artful" }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: { tag: "artful" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("ubuntu")
          expect(dependency.version).to eq("artful")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end
    end

    context "with a digest" do
      let(:dockerfile_fixture_name) { "digest" }
      let(:registry_tags) { fixture("docker", "registry_tags", "ubuntu.json") }
      let(:digest_headers) do
        JSON.parse(
          fixture("docker", "registry_manifest_headers", "ubuntu_12.04.5.json")
        )
      end

      let(:repo_url) { "https://registry.hub.docker.com/v2/library/ubuntu/" }

      before do
        auth_url = "https://auth.docker.io/token?service=registry.docker.io"
        stub_request(:get, auth_url).
          and_return(status: 200, body: { token: "token" }.to_json)

        tags_url = repo_url + "tags/list"
        stub_request(:get, tags_url).
          and_return(status: 200, body: registry_tags)
      end

      context "that doesn't match any tags" do
        let(:registry_tags) do
          fixture("docker", "registry_tags", "small_ubuntu.json")
        end
        before { digest_headers["docker_content_digest"] = "nomatch" }

        before do
          ubuntu_url = "https://registry.hub.docker.com/v2/library/ubuntu/"
          stub_request(:head, /#{Regexp.quote(ubuntu_url)}manifests/).
            and_return(status: 200, body: "", headers: digest_headers)
        end

        its(:length) { is_expected.to eq(0) }
      end

      context "that matches a tag" do
        before do
          stub_request(:head, repo_url + "manifests/10.04").
            and_return(status: 404)

          stub_request(:head, repo_url + "manifests/12.04.5").
            and_return(status: 200, body: "", headers: digest_headers)
        end

        its(:length) { is_expected.to eq(1) }

        describe "the first dependency" do
          subject(:dependency) { dependencies.first }
          let(:expected_requirements) do
            [{
              requirement: nil,
              groups: [],
              file: "Dockerfile",
              source: {
                digest: "sha256:18305429afa14ea462f810146ba44d4363ae76e4c8d"\
                        "fc38288cf73aa07485005"
              }
            }]
          end

          it "has the right details" do
            expect(dependency).to be_a(Dependabot::Dependency)
            expect(dependency.name).to eq("ubuntu")
            expect(dependency.version).to eq("12.04.5")
            expect(dependency.requirements).to eq(expected_requirements)
          end
        end

        context "for a private registry" do
          let(:dockerfile_fixture_name) { "private_digest" }
          let(:repo_url) { "https://registry-host.io:5000/v2/myreg/ubuntu/" }

          context "without no/bad authentication credentials" do
            before do
              tags_url = repo_url + "tags/list"
              stub_request(:get, tags_url).
                and_return(
                  status: 401,
                  body: "",
                  headers: { "www_authenticate" => "basic 123" }
                )
            end

            it "raises a PrivateSourceAuthenticationFailure error" do
              error_class = Dependabot::PrivateSourceAuthenticationFailure
              expect { parser.parse }.
                to raise_error(error_class) do |error|
                  expect(error.source).to eq("registry-host.io:5000")
                end
            end
          end

          context "with good authentication credentials" do
            let(:parser) do
              described_class.new(
                dependency_files: files,
                credentials: credentials,
                source: source
              )
            end
            let(:credentials) do
              [{
                "type" => "docker_registry",
                "registry" => "registry-host.io:5000",
                "username" => "grey",
                "password" => "pa55word"
              }]
            end

            its(:length) { is_expected.to eq(1) }

            describe "the first dependency" do
              subject(:dependency) { dependencies.first }
              let(:expected_requirements) do
                [{
                  requirement: nil,
                  groups: [],
                  file: "Dockerfile",
                  source: {
                    registry: "registry-host.io:5000",
                    digest: "sha256:18305429afa14ea462f810146ba44d4363ae76"\
                            "e4c8dfc38288cf73aa07485005"
                  }
                }]
              end

              it "has the right details" do
                expect(dependency).to be_a(Dependabot::Dependency)
                expect(dependency.name).to eq("myreg/ubuntu")
                expect(dependency.version).to eq("12.04.5")
                expect(dependency.requirements).to eq(expected_requirements)
              end
            end

            context "that don't include a username and password" do
              let(:credentials) do
                [{
                  "type" => "docker_registry",
                  "registry" => "registry-host.io:5000"
                }]
              end

              its(:length) { is_expected.to eq(1) }
            end
          end

          context "that uses Amazon ECR" do
            let(:dockerfile_fixture_name) { "private_ecr_digest" }
            let(:repo_url) do
              "https://695729449481.dkr.ecr.eu-west-2.amazonaws.com/v2/"\
              "docker-php/"
            end

            context "without credentials" do
              before do
                tags_url = repo_url + "tags/list"
                stub_request(:get, tags_url).
                  and_return(
                    status: 401,
                    body: "",
                    headers: { "www_authenticate" => "basic 123" }
                  )
              end

              it "raises a PrivateSourceAuthenticationFailure error" do
                error_class = Dependabot::PrivateSourceAuthenticationFailure
                expect { parser.parse }.
                  to raise_error(error_class) do |error|
                    expect(error.source).
                      to eq("695729449481.dkr.ecr.eu-west-2.amazonaws.com")
                  end
              end
            end

            context "with credentials" do
              let(:parser) do
                described_class.new(
                  dependency_files: files,
                  credentials: credentials,
                  source: source
                )
              end

              let(:credentials) do
                [{
                  "type" => "docker_registry",
                  "registry" => "695729449481.dkr.ecr.eu-west-2.amazonaws.com",
                  "username" => "grey",
                  "password" => "pa55word"
                }]
              end

              context "that are invalid" do
                before do
                  stub_request(
                    :post,
                    "https://api.ecr.eu-west-2.amazonaws.com/"
                  ).and_return(
                    status: 403,
                    body: fixture("docker", "ecr_responses", "invalid_token")
                  )
                end

                it "raises a PrivateSourceAuthenticationFailure error" do
                  error_class = Dependabot::PrivateSourceAuthenticationFailure
                  expect { parser.parse }.
                    to raise_error(error_class) do |error|
                      expect(error.source).
                        to eq("695729449481.dkr.ecr.eu-west-2.amazonaws.com")
                    end
                end
              end

              context "that are valid" do
                before do
                  stub_request(
                    :post,
                    "https://api.ecr.eu-west-2.amazonaws.com/"
                  ).and_return(
                    status: 200,
                    body: fixture("docker", "ecr_responses", "auth_data")
                  )
                end

                its(:length) { is_expected.to eq(1) }

                describe "the first dependency" do
                  subject(:dependency) { dependencies.first }
                  let(:expected_requirements) do
                    [{
                      requirement: nil,
                      groups: [],
                      file: "Dockerfile",
                      source: {
                        registry:
                          "695729449481.dkr.ecr.eu-west-2.amazonaws.com",
                        digest: "sha256:18305429afa14ea462f810146ba44d4363ae76"\
                                "e4c8dfc38288cf73aa07485005"
                      }
                    }]
                  end

                  it "has the right details" do
                    expect(dependency).to be_a(Dependabot::Dependency)
                    expect(dependency.name).to eq("docker-php")
                    expect(dependency.version).to eq("12.04.5")
                    expect(dependency.requirements).to eq(expected_requirements)
                  end
                end
              end
            end
          end
        end
      end
    end

    context "with a tag and digest" do
      let(:dockerfile_fixture_name) { "digest_and_tag" }
      let(:registry_tags) { fixture("docker", "registry_tags", "ubuntu.json") }
      let(:digest_headers) do
        JSON.parse(
          fixture("docker", "registry_manifest_headers", "ubuntu_12.04.5.json")
        )
      end

      let(:repo_url) { "https://registry.hub.docker.com/v2/library/ubuntu/" }

      subject(:dependency) { dependencies.first }

      before do
        auth_url = "https://auth.docker.io/token?service=registry.docker.io"
        stub_request(:get, auth_url).
          and_return(status: 200, body: { token: "token" }.to_json)

        tags_url = repo_url + "tags/list"
        stub_request(:get, tags_url).
          and_return(status: 200, body: registry_tags)
      end

      it "determines the correct version" do
        expect(dependency).to be_a(Dependabot::Dependency)
        expect(dependency.name).to eq("ubuntu")
        expect(dependency.version).to eq("12.04.5")
        expect(dependency.requirements).to eq([{
          requirement: nil,
          groups: [],
          file: "Dockerfile",
          source: {
            tag: "12.04.5",
            digest: "sha256:18305429afa14ea462f810146ba44d4363ae76e4c8dfc38288cf73aa07485005"
          }
        }])
      end
    end

    context "with multiple FROM lines" do
      let(:dockerfile_fixture_name) { "multiple" }

      its(:length) { is_expected.to eq(2) }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: { tag: "17.04" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("ubuntu")
          expect(dependency.version).to eq("17.04")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end

      describe "the second dependency" do
        subject(:dependency) { dependencies.last }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: { tag: "3.6.3" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("python")
          expect(dependency.version).to eq("3.6.3")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end

      context "that are identical" do
        let(:dockerfile_fixture_name) { "multiple_identical" }

        its(:length) { is_expected.to eq(1) }

        describe "the first dependency" do
          subject(:dependency) { dependencies.first }
          let(:expected_requirements) do
            [{
              requirement: nil,
              groups: [],
              file: "Dockerfile",
              source: { tag: "10-alpine" }
            }]
          end

          it "has the right details" do
            expect(dependency).to be_a(Dependabot::Dependency)
            expect(dependency.name).to eq("node")
            expect(dependency.version).to eq("10-alpine")
            expect(dependency.requirements).to eq(expected_requirements)
          end
        end
      end
    end

    context "with a v1 dockerhub reference and a tag" do
      let(:dockerfile_fixture_name) { "v1_tag" }

      its(:length) { is_expected.to eq(1) }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: { tag: "17.04" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("myreg/ubuntu")
          expect(dependency.version).to eq("17.04")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end
    end

    context "with a private registry and a tag" do
      let(:dockerfile_fixture_name) { "private_tag" }

      its(:length) { is_expected.to eq(1) }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: {
              registry: "registry-host.io:5000",
              tag: "17.04"
            }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("myreg/ubuntu")
          expect(dependency.version).to eq("17.04")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end

      context "when the registry has no port" do
        let(:dockerfile_fixture_name) { "private_no_port" }
        its(:length) { is_expected.to eq(1) }

        describe "the first dependency" do
          subject(:dependency) { dependencies.first }
          let(:expected_requirements) do
            [{
              requirement: nil,
              groups: [],
              file: "Dockerfile",
              source: {
                registry: "aws-account-id.dkr.ecr.region.amazonaws.com",
                tag: "17.04"
              }
            }]
          end

          it "has the right details" do
            expect(dependency).to be_a(Dependabot::Dependency)
            expect(dependency.name).to eq("myreg/ubuntu")
            expect(dependency.version).to eq("17.04")
            expect(dependency.requirements).to eq(expected_requirements)
          end
        end
      end
    end

    context "with a non-standard filename" do
      let(:dockerfile) do
        Dependabot::DependencyFile.new(
          name: "custom-name",
          content: dockerfile_body
        )
      end

      its(:length) { is_expected.to eq(1) }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "custom-name",
            source: { tag: "17.04" }
          }]
        end

        its(:requirements) { is_expected.to eq(expected_requirements) }
      end
    end

    context "with multiple dockerfiles" do
      let(:files) { [dockerfile, dockerfile2] }
      let(:dockerfile2) do
        Dependabot::DependencyFile.new(
          name: "custom-name",
          content: dockerfile_body2
        )
      end
      let(:dockerfile_body2) { fixture("docker", "dockerfiles", "namespace") }

      its(:length) { is_expected.to eq(2) }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: { tag: "17.04" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("ubuntu")
          expect(dependency.version).to eq("17.04")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end

      describe "the second dependency" do
        subject(:dependency) { dependencies.last }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "custom-name",
            source: { tag: "17.04" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("my-fork/ubuntu")
          expect(dependency.version).to eq("17.04")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end
    end

    context "with a platform" do
      let(:dockerfile_body) { "FROM --platform=linux/amd64 ubuntu:artful" }

      describe "the first dependency" do
        subject(:dependency) { dependencies.first }
        let(:expected_requirements) do
          [{
            requirement: nil,
            groups: [],
            file: "Dockerfile",
            source: { tag: "artful" }
          }]
        end

        it "has the right details" do
          expect(dependency).to be_a(Dependabot::Dependency)
          expect(dependency.name).to eq("ubuntu")
          expect(dependency.version).to eq("artful")
          expect(dependency.requirements).to eq(expected_requirements)
        end
      end
    end
  end
end

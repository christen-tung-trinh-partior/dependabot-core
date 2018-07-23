# frozen_string_literal: true

require "dependabot/file_fetchers/rust/cargo"
require_relative "../shared_examples_for_file_fetchers"

RSpec.describe Dependabot::FileFetchers::Rust::Cargo do
  it_behaves_like "a dependency file fetcher"

  let(:source) do
    Dependabot::Source.new(
      provider: "github",
      repo: "gocardless/bump",
      directory: "/"
    )
  end
  let(:file_fetcher_instance) do
    described_class.new(source: source, credentials: credentials)
  end
  let(:url) { "https://api.github.com/repos/gocardless/bump/contents/" }
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end

  let(:json_header) { { "content-type" => "application/json" } }
  before { allow(file_fetcher_instance).to receive(:commit).and_return("sha") }
  before do
    stub_request(:get, url + "Cargo.toml?ref=sha").
      with(headers: { "Authorization" => "token token" }).
      to_return(
        status: 200,
        body: fixture("github", "contents_cargo_manifest.json"),
        headers: json_header
      )

    stub_request(:get, url + "Cargo.lock?ref=sha").
      with(headers: { "Authorization" => "token token" }).
      to_return(
        status: 200,
        body: fixture("github", "contents_cargo_lockfile.json"),
        headers: json_header
      )
  end

  context "with a lockfile" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cargo_with_lockfile.json"),
          headers: json_header
        )
    end

    it "fetches the Cargo.toml and Cargo.lock" do
      expect(file_fetcher_instance.files.map(&:name)).
        to match_array(%w(Cargo.lock Cargo.toml))
    end
  end

  context "without a lockfile" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cargo_without_lockfile.json"),
          headers: json_header
        )
      stub_request(:get, url + "Cargo.lock?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(status: 404, headers: json_header)
    end

    it "fetches the Cargo.toml" do
      expect(file_fetcher_instance.files.map(&:name)).
        to eq(["Cargo.toml"])
    end
  end

  context "with a path dependency" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cargo_without_lockfile.json"),
          headers: json_header
        )
      stub_request(:get, url + "Cargo.toml?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(status: 200, body: parent_fixture, headers: json_header)
    end
    let(:parent_fixture) do
      fixture("github", "contents_cargo_manifest_path_deps.json")
    end

    context "that is fetchable" do
      before do
        stub_request(:get, url + "src/s3/Cargo.toml?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 200, body: path_dep_fixture, headers: json_header)
      end
      let(:path_dep_fixture) do
        fixture("github", "contents_cargo_manifest.json")
      end

      it "fetches the path dependency's Cargo.toml" do
        expect(file_fetcher_instance.files.map(&:name)).
          to match_array(%w(Cargo.toml src/s3/Cargo.toml))
        expect(file_fetcher_instance.files.last.type).
          to eq("path_dependency")
      end

      context "with a trailing slash in the path" do
        let(:parent_fixture) do
          fixture(
            "github",
            "contents_cargo_manifest_path_deps_trailing_slash.json"
          )
        end

        it "fetches the path dependency's Cargo.toml" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(Cargo.toml src/s3/Cargo.toml))
        end
      end

      context "for a target dependency" do
        let(:parent_fixture) do
          fixture(
            "github",
            "contents_cargo_manifest_target_path_deps.json"
          )
        end

        it "fetches the path dependency's Cargo.toml" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(Cargo.toml src/s3/Cargo.toml))
        end
      end

      context "with a directory" do
        let(:source) do
          Dependabot::Source.new(
            provider: "github",
            repo: "gocardless/bump",
            directory: "my_dir/"
          )
        end

        let(:url) do
          "https://api.github.com/repos/gocardless/bump/contents/my_dir/"
        end
        before do
          stub_request(:get, "https://api.github.com/repos/gocardless/bump/"\
                             "contents/my_dir?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(
              status: 200,
              body: fixture("github", "contents_cargo_without_lockfile.json"),
              headers: json_header
            )
        end

        it "fetches the path dependency's Cargo.toml" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(Cargo.toml src/s3/Cargo.toml))
          expect(file_fetcher_instance.files.map(&:path)).
            to match_array(%w(/my_dir/Cargo.toml /my_dir/src/s3/Cargo.toml))
        end
      end

      context "and includes another path dependency" do
        let(:path_dep_fixture) do
          fixture("github", "contents_cargo_manifest_path_deps.json")
        end

        before do
          stub_request(:get, url + "src/s3/src/s3/Cargo.toml?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(
              status: 200,
              body: fixture("github", "contents_cargo_manifest.json"),
              headers: json_header
            )
        end

        it "fetches the nested path dependency's Cargo.toml" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(
              %w(Cargo.toml src/s3/Cargo.toml src/s3/src/s3/Cargo.toml)
            )
        end
      end
    end

    context "that is not fetchable" do
      before do
        stub_request(:get, url + "src/s3/Cargo.toml?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 404, headers: json_header)
      end

      it "raises a DependencyFileNotFound error" do
        expect { file_fetcher_instance.files }.
          to raise_error(Dependabot::DependencyFileNotFound)
      end
    end
  end

  context "with a workspace dependency" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cargo_without_lockfile.json"),
          headers: json_header
        )
      stub_request(:get, url + "Cargo.toml?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(status: 200, body: parent_fixture, headers: json_header)
    end
    let(:parent_fixture) do
      fixture("github", "contents_cargo_manifest_workspace_root.json")
    end

    context "that is fetchable" do
      before do
        stub_request(:get, url + "lib/sub_crate/Cargo.toml?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 200, body: child_fixture, headers: json_header)
      end
      let(:child_fixture) do
        fixture("github", "contents_cargo_manifest_workspace_child.json")
      end

      it "fetches the workspace dependency's Cargo.toml" do
        expect(file_fetcher_instance.files.map(&:name)).
          to match_array(%w(Cargo.toml lib/sub_crate/Cargo.toml))
      end
    end

    context "that is not fetchable" do
      before do
        stub_request(:get, url + "lib/sub_crate/Cargo.toml?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 404, headers: json_header)
      end

      it "raises a DependencyFileNotFound error" do
        expect { file_fetcher_instance.files }.
          to raise_error(Dependabot::DependencyFileNotFound)
      end
    end

    context "that specifies a directory of packages" do
      let(:parent_fixture) do
        fixture("github", "contents_cargo_manifest_workspace_root_glob.json")
      end
      let(:child_fixture) do
        fixture("github", "contents_cargo_manifest_workspace_child.json")
      end
      let(:child_fixture2) do
        # This fixture also requires the first child as a path dependency,
        # so we're testing whether the first child gets fetched twice here, as
        # well as whether the second child gets fetched.
        fixture("github", "contents_cargo_manifest_workspace_child2.json")
      end

      before do
        stub_request(:get, url + "packages?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(
            status: 200,
            body: fixture("github", "contents_cargo_packages.json"),
            headers: json_header
          )
        stub_request(:get, url + "packages/sub_crate/Cargo.toml?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 200, body: child_fixture, headers: json_header)
        stub_request(:get, url + "packages/sub_crate2/Cargo.toml?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 200, body: child_fixture2, headers: json_header)
      end

      it "fetches the workspace dependency's Cargo.toml" do
        expect(file_fetcher_instance.files.map(&:name)).
          to match_array(
            %w(Cargo.toml
               packages/sub_crate/Cargo.toml
               packages/sub_crate2/Cargo.toml)
          )
        expect(file_fetcher_instance.files.map(&:type).uniq).
          to eq(["file"])
      end
    end
  end

  context "without a Cargo.toml" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_python.json"),
          headers: json_header
        )
      stub_request(:get, url + "Cargo.toml?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(status: 404, headers: json_header)
    end

    it "raises a DependencyFileNotFound error" do
      expect { file_fetcher_instance.files }.
        to raise_error(Dependabot::DependencyFileNotFound)
    end
  end
end

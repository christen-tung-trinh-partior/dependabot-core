# frozen_string_literal: true

require "excon"
require "nokogiri"
require "dependabot/update_checkers/dotnet/nuget"
require "dependabot/shared_helpers"

module Dependabot
  module UpdateCheckers
    module Dotnet
      class Nuget
        class RepositoryFinder
          DEFAULT_REPOSITORY_URL = "https://api.nuget.org/v3/index.json"

          def initialize(dependency:, credentials:, config_file: nil)
            @dependency  = dependency
            @credentials = credentials
            @config_file = config_file
          end

          def dependency_urls
            find_dependency_urls
          end

          private

          attr_reader :dependency, :credentials, :config_file

          def find_dependency_urls
            @find_dependency_urls ||=
              known_repositories.flat_map do |details|
                if details.fetch(:url) == DEFAULT_REPOSITORY_URL
                  # Save a request for the default URL, since we already how
                  # it addresses packages
                  next default_repository_details
                end

                repo_metadata_response = get_repo_metadata(details)
                next unless repo_metadata_response.status == 200

                base_url =
                  JSON.parse(repo_metadata_response.body).
                  fetch("resources", []).
                  find { |r| r.fetch("@type") == "PackageBaseAddress/3.0.0" }&.
                  fetch("@id")

                {
                  repository_url: details.fetch(:url),
                  versions_url:
                    File.join(base_url, dependency.name.downcase, "index.json"),
                  auth_header: auth_header_for_token(details.fetch(:token))
                }
              rescue Excon::Error::Timeout, Excon::Error::Socket
                nil
              end.compact.uniq
          end

          def get_repo_metadata(repo_details)
            Excon.get(
              repo_details.fetch(:url),
              headers: auth_header_for_token(repo_details.fetch(:token)),
              idempotent: true,
              **SharedHelpers.excon_defaults
            )
          end

          def known_repositories
            return @known_repositories if @known_repositories
            @known_repositories = []
            @known_repositories += credential_repositories
            @known_repositories += config_file_repositories

            if @known_repositories.empty?
              @known_repositories << { url: DEFAULT_REPOSITORY_URL, token: nil }
            end

            @known_repositories.uniq
          end

          def credential_repositories
            @credential_repositories ||=
              credentials.
              select { |cred| cred["type"] == "nuget_repository" }.
              map { |c| { url: c.fetch("url"), token: c.fetch("token") } }
          end

          def config_file_repositories
            return [] unless config_file

            doc = Nokogiri::XML(config_file.content)
            doc.remove_namespaces!
            sources =
              doc.css("configuration > packageSources > add").map do |node|
                {
                  key:
                    node.attribute("key")&.value&.strip ||
                      node.at_xpath("./key")&.content&.strip,
                  url:
                    node.attribute("value")&.value&.strip ||
                      node.at_xpath("./value")&.content&.strip
                }
              end

            sources.reject! do |s|
              known_urls = credential_repositories.map { |cr| cr.fetch(:url) }
              known_urls.include?(s.fetch(:url))
            end

            add_config_file_credentials(sources: sources, doc: doc)
            sources.each { |details| details.delete(:key) }

            sources
          end

          def default_repository_details
            {
              repository_url: DEFAULT_REPOSITORY_URL,
              versions_url:   "https://api.nuget.org/v3-flatcontainer/"\
                              "#{dependency.name.downcase}/index.json",
              auth_header:    {}
            }
          end

          def add_config_file_credentials(sources:, doc:)
            sources.each do |source_details|
              key = source_details.fetch(:key)
              next source_details[:token] = nil unless key
              tag = key.gsub(" ", "_x0020_")
              creds_nodes = doc.css("configuration > packageSourceCredentials "\
                                    "> #{tag} > add")

              username =
                creds_nodes.
                find { |n| n.attribute("key")&.value == "Username" }&.
                attribute("value")&.value
              password =
                creds_nodes.
                find { |n| n.attribute("key")&.value == "ClearTextPassword" }&.
                attribute("value")&.value

              # Note: We have to look for plain text passwords, as we have no
              # way of decrypting encrypted passwords. For the same reason we
              # don't fetch API keys from the nuget.config at all.
              next source_details[:token] = nil unless username && password

              source_details[:token] = "#{username}:#{password}"
            end

            sources
          end

          def auth_header_for_token(token)
            return {} unless token

            if token.include?(":")
              encoded_token = Base64.encode64(token).delete("\n")
              { "Authorization" => "Basic #{encoded_token}" }
            elsif Base64.decode64(token).ascii_only? &&
                  Base64.decode64(token).include?(":")
              { "Authorization" => "Basic #{token.delete("\n")}" }
            else
              { "Authorization" => "Bearer #{token}" }
            end
          end
        end
      end
    end
  end
end

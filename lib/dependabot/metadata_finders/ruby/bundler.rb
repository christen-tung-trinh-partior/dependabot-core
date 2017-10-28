# frozen_string_literal: true

require "dependabot/metadata_finders/base"

module Dependabot
  module MetadataFinders
    module Ruby
      class Bundler < Dependabot::MetadataFinders::Base
        SOURCE_KEYS = %w(
          source_code_uri
          homepage_uri
          wiki_uri
          bug_tracker_uri
          documentation_uri
          changelog_uri
          mailing_list_uri
          download_uri
        ).freeze

        def changelog_url
          if new_source_type == "default" && rubygems_listing["changelog_uri"]
            return rubygems_listing["changelog_uri"]
          end

          # Changelog won't be relevant for a git commit bump
          return if new_source_type == "git" && !ref_changed?

          super
        end

        private

        def look_up_source
          case new_source_type
          when "default" then find_source_from_rubygems_listing
          when "git" then find_source_from_git_url
          when "rubygems" then nil # Private rubygems server
          else raise "Unexpected source type: #{new_source_type}"
          end
        end

        def previous_ref
          dependency.previous_requirements.map do |r|
            r.dig(:source, "ref") || r.dig(:source, :ref)
          end.compact.first
        end

        def new_ref
          dependency.requirements.map do |r|
            r.dig(:source, "ref") || r.dig(:source, :ref)
          end.compact.first
        end

        def ref_changed?
          previous_ref && new_ref && previous_ref != new_ref
        end

        def new_source_type
          sources =
            dependency.requirements.map { |r| r.fetch(:source) }.uniq.compact

          return "default" if sources.empty?
          raise "Multiple sources! #{sources.join(', ')}" if sources.count > 1
          sources.first[:type] || sources.first.fetch("type")
        end

        def find_source_from_rubygems_listing
          source_url = rubygems_listing.
                       values_at(*SOURCE_KEYS).
                       compact.
                       find { |url| url =~ SOURCE_REGEX }

          return nil unless source_url
          source_url.match(SOURCE_REGEX).named_captures
        end

        def find_source_from_git_url
          info = dependency.requirements.map { |r| r[:source] }.compact.first

          url = info[:url] || info.fetch("url")
          return nil unless url.match?(SOURCE_REGEX)
          url.match(SOURCE_REGEX).named_captures
        end

        def rubygems_listing
          return @rubygems_listing unless @rubygems_listing.nil?

          response =
            Excon.get(
              "https://rubygems.org/api/v1/gems/#{dependency.name}.json",
              idempotent: true,
              middlewares: SharedHelpers.excon_middleware
            )

          @rubygems_listing = JSON.parse(response.body)
        rescue JSON::ParserError
          @rubygems_listing = {}
        end
      end
    end
  end
end

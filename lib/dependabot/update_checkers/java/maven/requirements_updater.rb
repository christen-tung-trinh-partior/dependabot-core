# frozen_string_literal: true

#######################################################
# For more details on Maven version constraints, see: #
# https://maven.apache.org/pom.html#Dependencies      #
#######################################################

require "dependabot/update_checkers/java/maven"
require "dependabot/utils/java/version"

module Dependabot
  module UpdateCheckers
    module Java
      class Maven
        class RequirementsUpdater
          VERSION_REGEX = /[0-9]+(?:\.[a-zA-Z0-9\-]+)*/

          def initialize(requirements:, latest_version:, source_url:)
            @requirements = requirements
            @source_url = source_url
            return unless latest_version
            @latest_version = version_class.new(latest_version)
          end

          def updated_requirements
            return requirements unless latest_version

            requirements.map do |req|
              next req if req.fetch(:requirement).nil?
              next req unless req.fetch(:requirement).match?(/\d/)
              next req if req.fetch(:requirement).include?(",")

              # Since range requirements are excluded by the line above we can
              # just do a `gsub` on anything that looks like a version
              new_req =
                req[:requirement].gsub(VERSION_REGEX, latest_version.to_s)
              req.merge(requirement: new_req, source: updated_source)
            end
          end

          private

          attr_reader :requirements, :latest_version, :source_url

          def version_class
            Utils::Java::Version
          end

          def updated_source
            { type: "maven_repo", url: source_url }
          end
        end
      end
    end
  end
end

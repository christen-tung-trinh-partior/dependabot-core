# typed: true
# frozen_string_literal: true

require "dependabot/version"
require "dependabot/utils"
require "dependabot/docker/tag"

module Dependabot
  module Docker
    # In the special case of Java, the version string may also contain
    # optional "update number" and "identifier" components.
    # See https://www.oracle.com/java/technologies/javase/versioning-naming.html
    # for a description of Java versions.
    #
    class Version < Dependabot::Version
      def initialize(version)
        release_part, update_part = version.split("_", 2)
        release_part = release_part.sub("v", "")

        # The numeric_version is needed here to validate the version string (ex: 20.9.0-alpine3.18)
        # when the call is made via Depenedabot Api to convert the image version to semver.
        release_part = Tag.new(release_part).numeric_version

        @release_part = Dependabot::Version.new(release_part.tr("-", "."))
        @update_part = Dependabot::Version.new(update_part&.start_with?(/[0-9]/) ? update_part : 0)

        super(@release_part)
      end

      def self.correct?(version)
        return true if version.is_a?(Gem::Version)

        # We can't call new here because Gem::Version calls self.correct? in its initialize method
        # causing an infinite loop, so instead we check if the release_part of the version is correct
        release_part, = version.split("_", 2)
        release_part = release_part.sub("v", "").tr("-", ".")
        super(release_part)
      rescue ArgumentError
        # if we can't instantiate a version, it can't be correct
        false
      end

      def to_semver
        @release_part.to_semver
      end

      def segments
        @release_part.segments
      end

      attr_reader :release_part

      def <=>(other)
        sort_criteria <=> other.sort_criteria
      end

      def sort_criteria
        [@release_part, @update_part]
      end
    end
  end
end

Dependabot::Utils
  .register_version_class("docker", Dependabot::Docker::Version)

# frozen_string_literal: true

require "dependabot/update_checkers/base"
require "dependabot/file_updaters/java/maven/declaration_finder"

module Dependabot
  module UpdateCheckers
    module Java
      class Maven < Dependabot::UpdateCheckers::Base
        require_relative "maven/requirements_updater"
        require_relative "maven/version_finder"
        require_relative "maven/property_updater"

        def latest_version
          @latest_version ||=
            begin
              versions = VersionFinder.new(dependency: dependency).versions
              versions = versions.reject(&:prerelease?) unless wants_prerelease?
              unless wants_date_based_version?
                versions = versions.reject { |v| v > version_class.new(1900) }
              end
              versions.last
            end
        end

        def latest_resolvable_version
          # TODO: Resolve the pom.xml to find the latest version we could update
          # to without updating any other dependencies at the same time
          #
          # The above is hard. Currently we just return the latest version and
          # hope (hence this package manager is in beta!)
          return nil if version_comes_from_multi_dependency_property?
          latest_version
        end

        def latest_resolvable_version_with_no_unlock
          # Irrelevant, since Maven has a single dependency file (the pom.xml).
          #
          # For completeness we ought to resolve the pom.xml and return the
          # latest version that satisfies the current constraint AND any
          # constraints placed on it by other dependencies. Seeing as we're
          # never going to take any action as a result, though, we just return
          # nil.
          nil
        end

        def updated_requirements
          RequirementsUpdater.new(
            requirements: dependency.requirements,
            latest_version: latest_version&.to_s
          ).updated_requirements
        end

        private

        def latest_version_resolvable_with_full_unlock?
          return false unless version_comes_from_multi_dependency_property?
          property_updater.update_possible?
        end

        def updated_dependencies_after_full_unlock
          property_updater.updated_dependencies
        end

        def wants_prerelease?
          return false unless dependency.version
          return false unless version_class.correct?(dependency.version)
          version_class.new(dependency.version).prerelease?
        end

        def wants_date_based_version?
          return false unless dependency.version
          return false unless version_class.correct?(dependency.version)
          version_class.new(dependency.version) >= version_class.new(100)
        end

        def numeric_version_up_to_date?
          return false unless version_class.correct?(dependency.version)
          super
        end

        def numeric_version_can_update?(requirements_to_unlock:)
          return false unless version_class.correct?(dependency.version)
          super
        end

        def property_updater
          @property_updater ||=
            PropertyUpdater.new(
              dependency: dependency,
              dependency_files: dependency_files,
              target_version: latest_version
            )
        end

        def version_comes_from_multi_dependency_property?
          declarations_using_a_property.any? do |requirement|
            req = requirement.fetch(:requirement)
            property =
              declaration_finder(req).declaration_node.at_css("version").content

            property_regex = /#{Regexp.escape(property)}/
            pom.content.scan(property_regex).count >
              dependency.requirements.select { |r| r == requirement }.count
          end
        end

        def declarations_using_a_property
          @declarations_using_a_property ||=
            dependency.requirements.select do |requirement|
              req_string = requirement.fetch(:requirement)
              declaration_finder(req_string).version_comes_from_property?
            end
        end

        def declaration_finder(requirement)
          @declaration_finder ||= {}
          @declaration_finder[requirement.hash] ||=
            FileUpdaters::Java::Maven::DeclarationFinder.new(
              dependency_name: dependency.name,
              dependency_requirement: requirement,
              pom_content: pom.content
            )
        end

        def pom
          @pom ||= dependency_files.find { |f| f.name == "pom.xml" }
        end
      end
    end
  end
end

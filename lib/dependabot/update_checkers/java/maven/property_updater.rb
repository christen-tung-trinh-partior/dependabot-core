# frozen_string_literal: true

require "dependabot/file_parsers/java/maven"
require "dependabot/update_checkers/java/maven"
require "dependabot/update_checkers/java/maven/requirements_updater"
require "dependabot/file_updaters/java/maven/declaration_finder"

module Dependabot
  module UpdateCheckers
    module Java
      class Maven
        class PropertyUpdater
          def initialize(dependency:, dependency_files:, target_version:)
            @dependency       = dependency
            @dependency_files = dependency_files
            @target_version   = target_version
          end

          def update_possible?
            return false unless target_version
            @update_possible ||=
              dependencies_using_property.all? do |dep|
                VersionFinder.new(dependency: dep).versions.
                  include?(target_version)
              end
          end

          def updated_dependencies
            raise "Update not possible!" unless update_possible?

            @updated_dependencies ||=
              dependencies_using_property.map do |dep|
                Dependency.new(
                  name: dep.name,
                  version: target_version.to_s,
                  requirements: updated_requirements,
                  previous_version: dep.version,
                  previous_requirements: dep.requirements,
                  package_manager: dep.package_manager
                )
              end
          end

          private

          attr_reader :dependency, :dependency_files, :target_version

          def dependencies_using_property
            @dependencies_using_property ||=
              FileParsers::Java::Maven.new(
                dependency_files: dependency_files,
                repo: nil
              ).parse.select { |dep| version_string(dep) == property_name }
          end

          def property_name
            @property_name ||= version_string(dependency)

            unless @property_name.start_with?("${")
              raise "Version '#{@property_name}' doesn't look like a property!"
            end

            @property_name
          end

          def version_string(dep)
            FileUpdaters::Java::Maven::DeclarationFinder.new(
              dependency_name: dep.name,
              dependency_requirement: dep.requirements.first[:requirement],
              pom_content: pom.content
            ).declaration_node.at_css("version")&.content
          end

          def pom
            dependency_files.find { |f| f.name == "pom.xml" }
          end

          def updated_requirements
            @updated_requirements ||=
              RequirementsUpdater.new(
                requirements: dependency.requirements,
                latest_version: target_version.to_s
              ).updated_requirements
          end
        end
      end
    end
  end
end

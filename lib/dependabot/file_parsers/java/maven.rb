# frozen_string_literal: true

require "nokogiri"

require "dependabot/dependency"
require "dependabot/file_parsers/base"

module Dependabot
  module FileParsers
    module Java
      class Maven < Dependabot::FileParsers::Base
        DEPENDENCY_SELECTOR = "dependencies > dependency, plugins plugin"

        def parse
          doc = Nokogiri::XML(pom.content)
          doc.css(DEPENDENCY_SELECTOR).map do |dependency_node|
            Dependency.new(
              name: dependency_name(dependency_node),
              version: dependency_version(dependency_node),
              package_manager: "maven",
              requirements: [{
                requirement: dependency_requirement(dependency_node),
                file: "pom.xml",
                groups: [],
                source: nil
              }]
            )
          end.compact
        end

        private

        def dependency_name(dependency_node)
          [
            dependency_node.at_css("groupId").content,
            dependency_node.at_css("artifactId").content
          ].join(":")
        end

        def dependency_version(dependency_node)
          requirement = dependency_requirement(dependency_node)
          return nil unless requirement

          # If a range is specified then we can't tell the exact version
          return nil if requirement.include?(",")

          # Remove brackets if present (and not denoting a range)
          requirement.gsub(/[\(\)\[\]]/, "")
        end

        def dependency_requirement(dependency_node)
          return unless dependency_node.at_css("version")
          version_content = dependency_node.at_css("version").content

          return version_content unless version_content.start_with?("${")

          property_name = version_content.strip[2..-2]
          doc = Nokogiri::XML(pom.content)
          doc.remove_namespaces!
          doc.at_xpath("//properties/#{property_name}").content
        end

        def pom
          @pom ||= get_original_file("pom.xml")
        end

        def check_required_files
          %w(pom.xml).each do |filename|
            raise "No #{filename}!" unless get_original_file(filename)
          end
        end
      end
    end
  end
end

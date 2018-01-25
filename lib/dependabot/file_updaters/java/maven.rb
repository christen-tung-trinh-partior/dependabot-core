# frozen_string_literal: true

require "nokogiri"
require "dependabot/file_updaters/base"
require "dependabot/file_parsers/java/maven"

module Dependabot
  module FileUpdaters
    module Java
      class Maven < Dependabot::FileUpdaters::Base
        DECLARATION_REGEX =
          %r{<parent>.*?</parent>|<dependency>.*?</dependency>|
             <plugin>.*?</plugin>}mx

        def self.updated_files_regex
          [/^pom\.xml$/]
        end

        def updated_dependency_files
          [updated_file(file: pom, content: updated_pom_content)]
        end

        private

        def dependency
          # For now, we'll only ever be updating a single dependency for Java
          dependencies.first
        end

        def check_required_files
          %w(pom.xml).each do |filename|
            raise "No #{filename}!" unless get_original_file(filename)
          end
        end

        def updated_pom_content
          updated_content =
            if original_pom_version_content.start_with?("${")
              prop_name = original_pom_version_content.strip[2..-2]
              pom.content.gsub(
                "<#{prop_name}>#{original_pom_requirement}</#{prop_name}>",
                "<#{prop_name}>#{updated_pom_requirement}</#{prop_name}>"
              )
            else
              pom.content.gsub(
                original_pom_declaration,
                updated_pom_declaration
              )
            end

          raise "Expected content to change!" if updated_content == pom.content
          updated_content
        end

        def original_pom_version_content
          Nokogiri::XML(original_pom_declaration).at_css("version").content
        end

        def original_pom_declaration
          deep_find_declarations(pom.content).find do |node|
            node = Nokogiri::XML(node)
            node_name = [
              node.at_css("groupId")&.content,
              node.at_css("artifactId")&.content
            ].compact.join(":")
            node_name == dependency.name
          end
        end

        def deep_find_declarations(string)
          string.scan(DECLARATION_REGEX).flat_map do |matching_node|
            [matching_node, *deep_find_declarations(matching_node[0..-2])]
          end
        end

        def updated_pom_declaration
          original_pom_declaration.gsub(
            "<version>#{original_pom_requirement}</version>",
            "<version>#{updated_pom_requirement}</version>"
          )
        end

        def updated_pom_requirement
          dependency.
            requirements.
            find { |f| f.fetch(:file) == "pom.xml" }.
            fetch(:requirement)
        end

        def original_pom_requirement
          dependency.
            previous_requirements.
            find { |f| f.fetch(:file) == "pom.xml" }.
            fetch(:requirement)
        end

        def pom
          @pom ||= get_original_file("pom.xml")
        end
      end
    end
  end
end

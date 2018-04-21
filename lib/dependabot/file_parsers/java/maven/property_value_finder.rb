# frozen_string_literal: true

require "nokogiri"

require "dependabot/dependency_file"
require "dependabot/file_parsers/java/maven"
require "dependabot/shared_helpers"

# For documentation, see the "Available Variables" section of
# http://maven.apache.org/guides/introduction/introduction-to-the-pom.html
module Dependabot
  module FileParsers
    module Java
      class Maven
        class PropertyValueFinder
          def initialize(dependency_files:)
            @dependency_files = dependency_files
          end

          def property_details(property_name:, callsite_pom:)
            pom = callsite_pom
            doc = Nokogiri::XML(pom.content)
            doc.remove_namespaces!

            # Loop through the paths that would satisfy this property name,
            # looking for one that exists in this POM
            temp_name = sanitize_property_name(property_name)
            node =
              loop do
                candidate_node = doc.at_xpath("//#{temp_name}") ||
                                 doc.at_xpath("//properties/#{temp_name}")
                break candidate_node if candidate_node
                break unless temp_name.include?(".")
                temp_name = temp_name.sub(".", "/")
              end

            # If we found a property, return it
            if node
              return { file: pom.name, node: node, value: node.content.strip }
            end

            # Otherwise, look for a value in this pom's parent
            return unless (parent = parent_pom(pom))
            property_details(
              property_name: property_name,
              callsite_pom: parent
            )
          end

          private

          attr_reader :dependency_files

          def pomfiles
            @pomfiles ||=
              dependency_files.select { |f| f.name.end_with?("pom.xml") }
          end

          def internal_dependency_poms
            return @internal_dependency_poms if @internal_dependency_poms

            @internal_dependency_poms = {}
            pomfiles.each do |pom|
              doc = Nokogiri::XML(pom.content)
              group_id    = doc.at_css("project > groupId") ||
                            doc.at_css("project > parent > groupId")
              artifact_id = doc.at_css("project > artifactId")

              next unless group_id && artifact_id

              dependency_name = [
                group_id.content.strip,
                artifact_id.content.strip
              ].join(":")

              @internal_dependency_poms[dependency_name] = pom
            end

            @internal_dependency_poms
          end

          def sanitize_property_name(property_name)
            property_name.sub(/^pom\./, "").sub(/^project\./, "")
          end

          def parent_pom(pom)
            doc = Nokogiri::XML(pom.content)
            doc.remove_namespaces!
            group_id = doc.at_xpath("//parent/groupId")&.content&.strip
            artifact_id = doc.at_xpath("//parent/artifactId")&.content&.strip
            version = doc.at_xpath("//parent/version")&.content&.strip

            return unless group_id && artifact_id
            name = [group_id, artifact_id].join(":")

            if internal_dependency_poms[name]
              return internal_dependency_poms[name]
            end

            fetch_remote_parent_pom(group_id, artifact_id, version)
          end

          def fetch_remote_parent_pom(group_id, artifact_id, version)
            maven_response = Excon.get(
              remote_pom_url(group_id, artifact_id, version),
              idempotent: true,
              middlewares: SharedHelpers.excon_middleware
            )
            return unless maven_response.status == 200

            DependencyFile.new(
              name: "remote_pom.xml",
              content: maven_response.body
            )
          end

          def remote_pom_url(group_id, artifact_id, version)
            "https://search.maven.org/remotecontent?filepath="\
            "#{group_id.tr('.', '/')}/#{artifact_id}/#{version}/"\
            "#{artifact_id}-#{version}.pom"
          end
        end
      end
    end
  end
end

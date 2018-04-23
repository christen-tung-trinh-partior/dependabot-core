# frozen_string_literal: true

require "nokogiri"
require "dependabot/file_updaters/base"
require "dependabot/file_parsers/java/maven"

module Dependabot
  module FileUpdaters
    module Java
      class Maven < Dependabot::FileUpdaters::Base
        require_relative "maven/declaration_finder"
        require_relative "maven/property_value_updater"

        def self.updated_files_regex
          [/^pom\.xml$/, %r{/pom\.xml$}]
        end

        def updated_dependency_files
          updated_files = pomfiles.dup

          # Loop through each of the changed requirements, applying changes to
          # all pomfiles for that change. Note that the logic is different here
          # to other languages because Java has property inheritance across
          # files
          dependencies.each do |dependency|
            updated_files = updated_pomfiles_for_dependency(
              updated_files,
              dependency
            )
          end

          updated_files = updated_files.reject { |f| pomfiles.include?(f) }

          raise "No files changed!" if updated_files.none?
          updated_files
        end

        private

        def check_required_files
          raise "No pom.xml!" unless get_original_file("pom.xml")
        end

        def updated_pomfiles_for_dependency(pomfiles, dependency)
          updated_pomfiles = pomfiles.dup

          dependency.requirements.each do |req|
            previous_req = dependency.previous_requirements.
                           find { |pr| pr.fetch(:file) == req.fetch(:file) }

            next if req == previous_req

            if updating_a_property?(dependency, req)
              updated_pomfiles = update_pomfiles_for_property_change(
                updated_pomfiles,
                dependency,
                req
              )
              pom = updated_pomfiles.find { |f| f.name == req.fetch(:file) }
              updated_pomfiles[updated_pomfiles.index(pom)] =
                remove_property_version_suffix_in_pom(dependency, pom, req)
            else
              pom = updated_pomfiles.find { |f| f.name == req.fetch(:file) }
              updated_pomfiles[updated_pomfiles.index(pom)] =
                update_version_in_pom(dependency, pom, req)
            end
          end

          updated_pomfiles
        end

        def update_pomfiles_for_property_change(pomfiles, dependency, req)
          declaration_string =
            Nokogiri::XML(original_pom_declaration(dependency, req)).
            at_css("version").content
          property_name =
            declaration_string.match(FileParsers::Java::Maven::PROPERTY_REGEX).
            named_captures.fetch("property")

          PropertyValueUpdater.new(dependency_files: pomfiles).
            update_pomfiles_for_property_change(
              property_name: property_name,
              callsite_pom: pomfiles.find { |f| f.name == req.fetch(:file) },
              updated_value: req.fetch(:requirement)
            )
        end

        def update_version_in_pom(dependency, pom, requirement)
          updated_content =
            pom.content.gsub(
              original_pom_declaration(dependency, requirement),
              updated_pom_declaration(dependency, requirement)
            )

          raise "Expected content to change!" if updated_content == pom.content
          updated_file(file: pom, content: updated_content)
        end

        def remove_property_version_suffix_in_pom(dep, pom, req)
          updated_content =
            pom.content.gsub(original_pom_declaration(dep, req)) do |old_dec|
              version_string =
                old_dec.match(%r{(?<=\<version\>).*(?=\</version\>)})
              cleaned_version_string = version_string.to_s.gsub(/(?<=\}).*/, "")

              old_dec.gsub(
                "<version>#{version_string}</version>",
                "<version>#{cleaned_version_string}</version>"
              )
            end

          updated_file(file: pom, content: updated_content)
        end

        def updating_a_property?(dependency, requirement)
          declaration_finder(dependency, requirement).
            version_comes_from_property?
        end

        def original_pom_declaration(dependency, requirement)
          declaration_finder(dependency, requirement).declaration_string
        end

        # The declaration finder may need to make remote calls (to get parent
        # POMs if it's searching for the value of a property), so we cache it.
        def declaration_finder(dependency, requirement)
          @declaration_finders ||= {}
          @declaration_finders[dependency.hash + requirement.hash] ||=
            begin
              original_req = original_pom_requirement(dependency, requirement)
              DeclarationFinder.new(
                dependency: dependency,
                declaring_requirement: original_req,
                dependency_files: dependency_files
              )
            end
        end

        def updated_pom_declaration(dependency, requirement)
          original_req_string =
            original_pom_requirement(dependency, requirement).
            fetch(:requirement)

          original_pom_declaration(dependency, requirement).gsub(
            %r{<version>\s*#{Regexp.quote(original_req_string)}\s*</version>},
            "<version>#{requirement.fetch(:requirement)}</version>"
          )
        end

        def original_pom_requirement(dependency, requirement)
          dependency.
            previous_requirements.
            find { |f| f.fetch(:file) == requirement.fetch(:file) }
        end

        def pomfiles
          @pomfiles ||=
            dependency_files.select { |f| f.name.end_with?("pom.xml") }
        end
      end
    end
  end
end

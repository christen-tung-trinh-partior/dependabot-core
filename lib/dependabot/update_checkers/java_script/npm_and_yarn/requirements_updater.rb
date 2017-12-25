# frozen_string_literal: true

################################################################################
# For more details on Composer version constraints, see:                       #
# https://docs.npmjs.com/misc/semver                                           #
################################################################################

require "dependabot/update_checkers/java_script/npm_and_yarn"
require "dependabot/update_checkers/java_script/npm_and_yarn/version"

module Dependabot
  module UpdateCheckers
    module JavaScript
      class NpmAndYarn
        class RequirementsUpdater
          VERSION_REGEX = /[0-9]+(?:\.[A-Za-z0-9\-_]+)*/
          AND_SEPARATOR = /(?<=[a-zA-Z0-9*])\s+(?!\s*[|-])/
          OR_SEPARATOR = /(?<=[a-zA-Z0-9*])\s*\|+/
          SEPARATOR = /(?<=[a-zA-Z0-9*])[\s|]+(?![\s|-])/

          def initialize(requirements:, library:,
                         latest_version:, latest_resolvable_version:)
            @requirements = requirements
            @library = library
            if latest_version
              @latest_version = version_class.new(latest_version)
            end

            return unless latest_resolvable_version
            @latest_resolvable_version =
              version_class.new(latest_resolvable_version)
          end

          def updated_requirements
            return requirements unless latest_resolvable_version

            requirements.map do |req|
              if library?
                updated_library_requirement(req)
              else
                updated_app_requirement(req)
              end
            end
          end

          private

          attr_reader :requirements, :latest_version, :latest_resolvable_version

          def library?
            @library
          end

          def updated_app_requirement(req)
            current_requirement = req[:requirement]

            if current_requirement.match?(/(<|-\s)/i)
              ruby_req = ruby_requirements(current_requirement).first
              return req if ruby_req.satisfied_by?(latest_resolvable_version)
              updated_req = update_range_requirement(current_requirement)
              return req.merge(requirement: updated_req)
            end

            req.merge(requirement: update_version_string(current_requirement))
          end

          def updated_library_requirement(req)
            current_requirement = req[:requirement]
            version = latest_resolvable_version
            return req if current_requirement.strip == ""

            ruby_reqs = ruby_requirements(current_requirement)
            return req if ruby_reqs.any? { |r| r.satisfied_by?(version) }

            reqs = current_requirement.strip.split(SEPARATOR).map(&:strip)

            updated_requirement =
              if reqs.any? { |r| r.match?(/(<|-\s)/i) }
                update_range_requirement(current_requirement)
              elsif current_requirement.strip.split(SEPARATOR).count == 1
                update_version_string(current_requirement)
              else
                current_requirement
              end

            req.merge(requirement: updated_requirement)
          end

          def ruby_requirements(requirement_string)
            requirement_string.strip.split(OR_SEPARATOR).map do |req_string|
              req_string = req_string.gsub(/(?:\.|^)[xX*]/, "")

              ruby_requirements =
                req_string.strip.split(AND_SEPARATOR).map do |r_string|
                  if r_string.start_with?("~")
                    ruby_tilde_range(r_string)
                  elsif r_string.start_with?("^")
                    ruby_caret_range(r_string)
                  elsif r_string.include?(" - ")
                    ruby_hyphen_range(r_string)
                  elsif r_string.include?("<") || r_string.include?(">")
                    Gem::Requirement.new(r_string)
                  else
                    ruby_range(r_string)
                  end
                end

              Gem::Requirement.new(ruby_requirements.join(",").split(","))
            end
          end

          def ruby_hyphen_range(req_string)
            lower_bound, upper_bound = req_string.split(/\s+-\s+/)
            Gem::Requirement.new(">= #{lower_bound}", "<= #{upper_bound}")
          end

          def ruby_tilde_range(req_string)
            version = req_string.gsub(/^~/, "")
            parts = version.split(".")
            parts << "0" if parts.count < 3
            Gem::Requirement.new("~> #{parts.join('.')}")
          end

          def ruby_range(req_string)
            parts = req_string.split(".")
            parts << "0" if parts.count < 3
            Gem::Requirement.new("~> #{parts.join('.')}")
          end

          def ruby_caret_range(req_string)
            version = req_string.gsub(/^\^/, "")
            parts = version.split(".")
            first_non_zero = parts.find { |d| d != "0" }
            first_non_zero_index =
              first_non_zero ? parts.index(first_non_zero) : parts.count - 1
            upper_bound = parts.map.with_index do |part, i|
              if i < first_non_zero_index then part
              elsif i == first_non_zero_index then (part.to_i + 1).to_s
              else 0
              end
            end.join(".")

            Gem::Requirement.new(">= #{version}", "< #{upper_bound}")
          end

          def update_range_requirement(req_string)
            range_requirements =
              req_string.split(SEPARATOR).select { |r| r.match?(/<|(\s+-\s+)/) }

            if range_requirements.count == 1
              range_requirement = range_requirements.first
              versions = range_requirement.scan(VERSION_REGEX)
              upper_bound = versions.map { |v| version_class.new(v) }.max
              new_upper_bound = update_greatest_version(
                upper_bound,
                latest_resolvable_version
              )

              req_string.sub(
                upper_bound.to_s,
                new_upper_bound.to_s
              )
            else
              req_string + " || ^#{latest_resolvable_version}"
            end
          end

          def update_version_string(req_string)
            req_string.
              sub(VERSION_REGEX) do |old_version|
                if old_version.match?(/\d-/)
                  latest_resolvable_version.to_s
                else
                  old_parts = old_version.split(".")
                  new_parts = latest_resolvable_version.to_s.split(".").
                              first(old_parts.count)
                  new_parts.map.with_index do |part, i|
                    old_parts[i].match?(/^x\b/) ? "x" : part
                  end.join(".")
                end
              end
          end

          def update_greatest_version(old_version, version_to_be_permitted)
            version = version_class.new(old_version)
            version = version.release if version.prerelease?

            index_to_update =
              version.segments.map.with_index { |seg, i| seg.zero? ? 0 : i }.max

            version.segments.map.with_index do |_, index|
              if index < index_to_update
                version_to_be_permitted.segments[index]
              elsif index == index_to_update
                version_to_be_permitted.segments[index] + 1
              else 0
              end
            end.join(".")
          end

          def version_class
            NpmAndYarn::Version
          end
        end
      end
    end
  end
end

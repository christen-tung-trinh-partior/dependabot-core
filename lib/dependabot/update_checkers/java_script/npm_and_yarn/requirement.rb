# frozen_string_literal: true

require "dependabot/update_checkers/java_script/npm_and_yarn/version"

module Dependabot
  module UpdateCheckers
    module JavaScript
      class NpmAndYarn
        class Requirement < Gem::Requirement
          def initialize(*requirements)
            requirements = requirements.flatten.flat_map do |req_string|
              convert_js_constraint_to_ruby_constraint(req_string)
            end

            super(requirements)
          end

          private

          def convert_js_constraint_to_ruby_constraint(req_string)
            req_string = req_string.gsub(/(?:\.|^)[xX*]/, "")

            if req_string.match?(/^~[^>]/) then convert_tilde_req(req_string)
            elsif req_string.start_with?("^") then convert_caret_req(req_string)
            elsif req_string.include?(" - ") then convert_hyphen_req(req_string)
            elsif req_string.match?(/[<>]/) then req_string
            else ruby_range(req_string)
            end
          end

          def convert_tilde_req(req_string)
            version = req_string.gsub(/^~/, "")
            parts = version.split(".")
            parts << "0" if parts.count < 3
            "~> #{parts.join('.')}"
          end

          def convert_hyphen_req(req_string)
            lower_bound, upper_bound = req_string.split(/\s+-\s+/)
            [">= #{lower_bound}", "<= #{upper_bound}"]
          end

          def ruby_range(req_string)
            parts = req_string.split(".")
            parts << "0" if parts.count < 3
            "~> #{parts.join('.')}"
          end

          def convert_caret_req(req_string)
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

            [">= #{version}", "< #{upper_bound}"]
          end
        end
      end
    end
  end
end

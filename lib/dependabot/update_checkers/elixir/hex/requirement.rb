# frozen_string_literal: true

require "dependabot/update_checkers/elixir/hex/version"

# rubocop:disable all
module Dependabot
  module UpdateCheckers
    module Elixir
      class Hex
        class Requirement < Gem::Requirement
          OPS["=="] = lambda { |v, r| v == r }

          # Override the version pattern to allow local versions
          quoted = OPS.keys.map { |k| Regexp.quote k }.join "|"
          PATTERN_RAW =
            "\\s*(#{quoted})?\\s*(#{Hex::Version::VERSION_PATTERN})\\s*"
          PATTERN = /\A#{PATTERN_RAW}\z/

          # Override the parser to create Hex::Versions
          def self.parse obj
            return ["=", obj] if Gem::Version === obj

            unless PATTERN =~ obj.to_s
              raise BadRequirementError, "Illformed requirement [#{obj.inspect}]"
            end

            if $1 == ">=" && $2 == "0"
              DefaultRequirement
            else
              [$1 || "=", Hex::Version.new($2)]
            end
          end

          def satisfied_by?(version)
            version = Hex::Version.new(version.to_s)
            super
          end
        end
      end
    end
  end
end
# rubocop:enable all

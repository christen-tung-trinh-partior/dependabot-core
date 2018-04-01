# frozen_string_literal: true

require "dependabot/utils/python/version"
require "dependabot/utils/elixir/version"
require "dependabot/utils/java/version"
require "dependabot/utils/java_script/version"
require "dependabot/utils/php/version"
require "dependabot/utils/rust/version"

require "dependabot/utils/elixir/requirement"
require "dependabot/utils/java_script/requirement"
require "dependabot/utils/php/requirement"
require "dependabot/utils/python/requirement"
require "dependabot/utils/rust/requirement"

# rubocop:disable Metrics/CyclomaticComplexity
module Dependabot
  module Utils
    def self.version_class_for_package_manager(package_manager)
      case package_manager
      when "bundler", "submodules", "docker" then Gem::Version
      when "maven" then Utils::Java::Version
      when "npm_and_yarn" then Utils::JavaScript::Version
      when "pip" then Utils::Python::Version
      when "composer" then Utils::Php::Version
      when "hex" then Utils::Elixir::Version
      when "cargo" then Utils::Rust::Version
      else raise "Unsupported package_manager #{package_manager}"
      end
    end

    def self.requirement_class_for_package_manager(package_manager)
      case package_manager
      when "bundler", "maven", "submodules", "docker" then Gem::Requirement
      when "npm_and_yarn" then Utils::JavaScript::Requirement
      when "pip" then Utils::Python::Requirement
      when "composer" then Utils::Php::Requirement
      when "hex" then Utils::Elixir::Requirement
      when "cargo" then Utils::Rust::Requirement
      else raise "Unsupported package_manager #{package_manager}"
      end
    end
  end
end
# rubocop:enable Metrics/CyclomaticComplexity

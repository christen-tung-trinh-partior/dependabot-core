# frozen_string_literal: true

require "nokogiri"

require "dependabot/dependency"
require "dependabot/file_parsers/base"

# For details on how dotnet handles version constraints, see:
# https://docs.microsoft.com/en-us/nuget/reference/package-versioning
module Dependabot
  module FileParsers
    module Dotnet
      class Nuget < Dependabot::FileParsers::Base
        require "dependabot/file_parsers/base/dependency_set"
        require "dependabot/file_parsers/dotnet/nuget/project_file_parser"
        require "dependabot/file_parsers/dotnet/nuget/packages_config_parser"

        PACKAGE_CONF_DEPENDENCY_SELECTOR = "packages > packages"

        def parse
          dependency_set = DependencySet.new
          dependency_set += project_file_dependencies
          dependency_set += packages_config_dependencies
          dependency_set.dependencies
        end

        private

        def project_file_dependencies
          dependency_set = DependencySet.new

          (project_files + project_import_files).each do |file|
            parser = project_file_parser
            dependency_set += parser.dependency_set(project_file: file)
          end

          dependency_set
        end

        def packages_config_dependencies
          return DependencySet.new unless packages_config

          PackagesConfigParser.
            new(packages_config: packages_config).
            dependency_set
        end

        def project_file_parser
          @project_file_parser ||=
            ProjectFileParser.new(dependency_files: dependency_files)
        end

        def project_files
          dependency_files.select { |df| df.name.match?(/\.[a-z]{2}proj$/) }
        end

        def packages_config
          dependency_files.find { |f| f.name.casecmp("packages.config").zero? }
        end

        def project_import_files
          dependency_files - [packages_config, nuget_config]
        end

        def nuget_config
          dependency_files.find { |f| f.name.casecmp("nuget.config").zero? }
        end

        def check_required_files
          return if project_files.any? || packages_config

          raise "No project file or packages.config!"
        end
      end
    end
  end
end

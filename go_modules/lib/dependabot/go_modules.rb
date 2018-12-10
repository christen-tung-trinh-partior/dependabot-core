# frozen_string_literal: true

# These all need to be required so the various classes can be registered in a
# lookup table of package manager names to concrete classes.
require "dependabot/go_modules/file_fetcher"
require "dependabot/go_modules/file_parser"

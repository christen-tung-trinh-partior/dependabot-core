# frozen_string_literal: true

require "parser/current"
require "dependabot/file_updaters/ruby/bundler"

module Dependabot
  module FileUpdaters
    module Ruby
      class Bundler
        class GemspecSanitizer
          UNNECESSARY_ASSIGNMENTS = %i(
            bindir=
            cert_chain=
            email=
            executables=
            extra_rdoc_files=
            homepage=
            license=
            licenses=
            metadata=
            post_install_message=
            rdoc_options=
          ).freeze

          attr_reader :replacement_version

          def initialize(replacement_version:)
            @replacement_version = replacement_version
          end

          def rewrite(content)
            buffer = Parser::Source::Buffer.new("(gemspec_content)")
            buffer.source = content
            ast = Parser::CurrentRuby.new.parse(buffer)

            Rewriter.
              new(replacement_version: replacement_version).
              rewrite(buffer, ast)
          end

          class Rewriter < Parser::TreeRewriter
            def initialize(replacement_version:)
              @replacement_version = replacement_version
            end

            def on_send(node)
              # Remove any `require` or `require_relative` calls, as we won't
              # have the required files
              remove(node.loc.expression) if requires_file?(node)

              # Remove any assignments to a VERSION constant (or similar), as
              # that constant probably comes from a required file
              replace_constant(node) if node_assigns_to_version_constant?(node)

              # Replace the `s.files= ...` assignment with a blank array, as
              # occassionally a File.open(..).readlines pattern is used
              replace_file_assignment(node) if node_assigns_files_to_var?(node)

              # Replace the `s.require_path= ...` assignment, as
              # occassionally a Dir['lib'] pattern is used
              if node_assigns_require_paths?(node)
                replace_require_paths_assignment(node)
              end

              # Replace any `File.read(...)` calls with a dummy string
              replace_file_reads(node)

              remove_unnecessary_assignments(node)
            end

            private

            attr_reader :replacement_version

            def requires_file?(node)
              %i(require require_relative).include?(node.children[1])
            end

            def node_assigns_to_version_constant?(node)
              return false unless node.is_a?(Parser::AST::Node)
              return false unless node.children.first.is_a?(Parser::AST::Node)
              return false unless node.children.first&.type == :lvar

              return true if node.children[1] == :version=
              return true if node_is_version_constant?(node.children.last)
              return true if node_calls_version_constant?(node.children.last)

              node_interpolates_version_constant?(node.children.last)
            end

            def node_assigns_files_to_var?(node)
              return false unless node.is_a?(Parser::AST::Node)
              return false unless node.children.first.is_a?(Parser::AST::Node)
              return false unless node.children.first&.type == :lvar
              return false unless node.children[1] == :files=

              node.children[2]&.type == :send
            end

            def node_assigns_require_paths?(node)
              return false unless node.is_a?(Parser::AST::Node)
              return false unless node.children.first.is_a?(Parser::AST::Node)
              return false unless node.children.first&.type == :lvar

              node.children[1] == :require_paths=
            end

            def replace_file_reads(node)
              return unless node.is_a?(Parser::AST::Node)
              return if node.children[1] == :version=
              return replace_file_read(node) if node_reads_a_file?(node)

              node.children.each { |child| replace_file_reads(child) }
            end

            def node_reads_a_file?(node)
              return false unless node.is_a?(Parser::AST::Node)
              return false unless node.children.first.is_a?(Parser::AST::Node)
              return false unless node.children.first&.type == :const
              return false unless node.children.first.children.last == :File

              node.children[1] == :read
            end

            def remove_unnecessary_assignments(node)
              return unless node.is_a?(Parser::AST::Node)

              if unnecessary_assignment?(node) &&
                 node.children.last&.location&.respond_to?(:heredoc_end)
                range_to_remove = node.loc.expression.join(
                  node.children.last.location.heredoc_end
                )
                return remove(range_to_remove)
              elsif unnecessary_assignment?(node)
                return remove(node.loc.expression)
              end

              node.children.each do |child|
                remove_unnecessary_assignments(child)
              end
            end

            def unnecessary_assignment?(node)
              return false unless node.is_a?(Parser::AST::Node)
              return false unless node.children.first.is_a?(Parser::AST::Node)
              return false unless node.children.first&.type == :lvar

              UNNECESSARY_ASSIGNMENTS.include?(node.children[1])
            end

            def node_is_version_constant?(node)
              return false unless node.is_a?(Parser::AST::Node)
              return false unless node.type == :const

              node.children.last.to_s.match?(/version/i)
            end

            def node_calls_version_constant?(node)
              return false unless node.is_a?(Parser::AST::Node)
              return false unless node.type == :send

              node.children.any? { |n| node_is_version_constant?(n) }
            end

            def node_interpolates_version_constant?(node)
              return false unless node.is_a?(Parser::AST::Node)
              return false unless node.type == :dstr

              node.children.
                select { |n| n.type == :begin }.
                flat_map(&:children).
                any? { |n| node_is_version_constant?(n) }
            end

            def replace_constant(node)
              case node.children.last&.type
              when :str then nil # no-op
              when :const, :send, :lvar
                replace(
                  node.children.last.loc.expression,
                  %("#{replacement_version}")
                )
              when :dstr
                node.children.last.children.
                  select { |n| n.type == :begin }.
                  flat_map(&:children).
                  select { |n| node_is_version_constant?(n) }.
                  each do |n|
                    replace(
                      n.loc.expression,
                      %("#{replacement_version}")
                    )
                  end
              else
                raise "Unexpected node type #{node.children.last&.type}"
              end
            end

            def replace_file_assignment(node)
              replace(node.children.last.loc.expression, "[]")
            end

            def replace_require_paths_assignment(node)
              replace(node.children.last.loc.expression, "['lib']")
            end

            def replace_file_read(node)
              replace(node.loc.expression, '"text"')
            end
          end
        end
      end
    end
  end
end

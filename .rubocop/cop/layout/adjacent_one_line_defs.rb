# frozen_string_literal: true

module RuboCop
  module Cop
    module Layout
      # .rubocop.yml loads this for compact groups of adjacent endless method definitions.
      class AdjacentOneLineDefs < Base
        include RangeHelp
        extend AutoCorrector

        MSG = "Remove empty lines between adjacent one-line method definitions."

        def on_def(node) = check(node)
        alias on_defs on_def

        private

        def check(node)
          following = node.right_sibling
          return unless separated_one_line_defs?(node, following)
          return if comments_between?(node, following)

          spacing = range_between(node.source_range.end_pos, following.source_range.begin_pos)
          add_offense(spacing) do
            it.replace(spacing, "\n#{" " * following.loc.column}")
          end
        end

        def separated_one_line_defs?(node, following)
          node.single_line? && following&.any_def_type? && following.single_line? &&
            following.first_line > node.last_line + 1
        end

        def comments_between?(node, following)
          processed_source.comments.any? do
            it.location.line.between?(node.last_line + 1, following.first_line - 1)
          end
        end
      end
    end
  end
end

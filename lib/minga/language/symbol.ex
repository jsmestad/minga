defmodule Minga.Language.Symbol do
  @moduledoc """
  A document symbol extracted from a tree-sitter `tags.scm` query.

  Symbols are flat parser facts: name, kind, and source range. Presentation layers can derive hierarchy from range containment when they need breadcrumbs or outlines.
  """

  @typedoc "Symbol kind normalized from `@definition.*` captures."
  @type kind :: :function | :module | :method | :interface | :test

  @typedoc "Zero-based source range `{start_row, start_col, end_row, end_col}`."
  @type range :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @enforce_keys [:kind, :name, :range]
  defstruct [:kind, :name, :range]

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t(),
          range: range()
        }
end

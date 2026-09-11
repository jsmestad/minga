defmodule MingaEditor.UI.Theme.Palette.Syntax do
  @moduledoc """
  Syntax palette colors for theme authoring.

  These drive tree-sitter and markup capture colors.
  """

  alias MingaEditor.UI.Theme
  alias MingaEditor.UI.Theme.Palette.{Base, Semantic}

  defstruct [
    :builtin,
    :functions,
    :keywords,
    :methods,
    :operators,
    :constants,
    :strings,
    :numbers,
    :type,
    :variables,
    :comments
  ]

  @type color :: Theme.color()

  @type t :: %__MODULE__{
          builtin: color() | nil,
          functions: color() | nil,
          keywords: color() | nil,
          methods: color() | nil,
          operators: color() | nil,
          constants: color() | nil,
          strings: color() | nil,
          numbers: color() | nil,
          type: color() | nil,
          variables: color() | nil,
          comments: color() | nil
        }

  @doc "Builds the syntax palette from a flat theme map."
  @spec new(map(), Semantic.t(), Base.t()) :: t()
  def new(attrs, semantic, base) when is_map(attrs) do
    functions = Base.optional_color(attrs, :functions, semantic.info)

    %__MODULE__{
      builtin: Base.optional_color(attrs, :builtin, semantic.info),
      functions: functions,
      keywords: Base.optional_color(attrs, :keywords, semantic.highlight),
      methods: Base.optional_color(attrs, :methods, functions),
      operators: Base.optional_color(attrs, :operators, semantic.accent),
      constants: Base.optional_color(attrs, :constants, semantic.warning),
      strings: Base.optional_color(attrs, :strings, semantic.success),
      numbers: Base.optional_color(attrs, :numbers, semantic.warning),
      type: Base.optional_color(attrs, :type, semantic.warning),
      variables: Base.optional_color(attrs, :variables, base.fg),
      comments: Base.optional_color(attrs, :comments, base.muted)
    }
  end
end

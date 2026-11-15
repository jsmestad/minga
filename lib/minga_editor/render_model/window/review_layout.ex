defmodule MingaEditor.RenderModel.Window.ReviewLayout do
  @moduledoc "Wrapping and theme inputs for resident read-only review rows."

  alias Minga.Core.Face
  alias Minga.Core.WidthOracle
  alias Minga.RenderModel.Window.Span
  alias MingaEditor.Agent.DiffReview.DisplayLine
  alias MingaEditor.UI.Theme

  @enforce_keys [:text_width, :oracle, :theme, :tab_width]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          text_width: pos_integer(),
          oracle: WidthOracle.t(),
          theme: Theme.t(),
          tab_width: pos_integer()
        }

  @doc "Captures pane capacity with a stable one-column presentation margin, without deriving rows from pixels."
  @spec new(pos_integer(), WidthOracle.t(), Theme.t(), pos_integer()) :: t()
  def new(pane_width, oracle, %Theme{} = theme, tab_width)
      when is_integer(pane_width) and pane_width > 0 and is_integer(tab_width) and tab_width > 0 do
    %__MODULE__{
      text_width: max(pane_width - 1, 1),
      oracle: oracle,
      theme: theme,
      tab_width: tab_width
    }
  end

  @doc "Identifies layout compatibility independently of color changes."
  @spec identity_key(t()) :: tuple()
  def identity_key(%__MODULE__{} = layout) do
    {layout.text_width, WidthOracle.fingerprint(layout.oracle), layout.tab_width}
  end

  @doc "Identifies the exact resolved colors used by review rows."
  @spec style_key(t()) :: tuple()
  def style_key(%__MODULE__{theme: theme}) do
    {theme.editor.fg, theme.editor.bg, theme.git.added_fg, theme.git.deleted_fg,
     theme.git.modified_fg}
  end

  @doc "Resolves a diff line's appearance through the current theme."
  @spec span(t(), DisplayLine.kind()) :: Span.t()
  def span(%__MODULE__{theme: theme, text_width: text_width}, kind) do
    face = %Face{
      name: "agent.review",
      fg: foreground(theme, kind),
      bg: theme.editor.bg,
      bold: kind == :hunk_header
    }

    Span.from_face(face, 0, text_width)
  end

  @spec foreground(Theme.t(), DisplayLine.kind()) :: Theme.color()
  defp foreground(theme, :context), do: theme.editor.fg
  defp foreground(theme, :added), do: theme.git.added_fg
  defp foreground(theme, :removed), do: theme.git.deleted_fg
  defp foreground(theme, :hunk_header), do: theme.git.modified_fg
end

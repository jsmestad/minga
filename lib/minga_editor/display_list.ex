defmodule MingaEditor.DisplayList do
  @moduledoc """
  Cell-grid draw primitives for chrome surfaces.

  The buffer/window render path is fully semantic: editor windows build
  `Minga.RenderModel.Window` models that frontend adapters encode directly
  (see `MingaEditor.RenderPipeline.Content` and `RenderModel.Window.Builder`).
  The dead cell-grid window carriers (`Frame`, `WindowFrame`) and their line
  producers were removed in #2241.

  The per-surface chrome painters (completion menu, dashboard, hover/signature
  popups, modeline, tab bar, float popups, etc.) were deleted in #2311; the
  semantic frontends render those surfaces natively. `draw/4` and the `Overlay`
  carrier are retained for the remaining legitimate consumers:

    * `Minga.Core.Decorations.BlockDecoration` — raw draw tuples for extension
      block decorations.
    * `FloatingWindow.Spec` / `HoverPopup` / `SignatureHelp` — the `:content`
      draw list type used to compute popup geometry for `box/3`.
    * `RenderPipeline.Chrome` / `ComposeHelpers` — the `Overlay` carrier, whose
      `cursor` field still resolves the picker cursor in Compose.
    * The Git Porcelain extension shell renderer.

  ## Types

  * `draw()` — a pending draw: `{row, col, text, style}`.
  * `text_run()` — column + text + style (no row; row is the map key).
  * `display_line()` — a list of text runs for one screen row.
  * `render_layer()` — rows mapped to their display lines.
  """

  alias Minga.Core.Face

  # ── Fundamental types ──────────────────────────────────────────────────────

  @typedoc "RGB color as a 24-bit integer (e.g. `0xFF6C6B`)."
  @type color :: non_neg_integer()

  @typedoc "Style: a resolved Face struct."
  @type style :: Face.t()

  @typedoc """
  A pending draw command: `{row, col, text, Face.t()}`.

  This is the intermediate representation that chrome-surface painters produce.
  """
  @type draw :: {non_neg_integer(), non_neg_integer(), String.t(), Face.t()}

  @typedoc "A single styled text span at a specific column."
  @type text_run :: {col :: non_neg_integer(), text :: String.t(), style :: Face.t()}

  @typedoc "All text runs on one screen row."
  @type display_line :: [text_run()]

  @typedoc "Screen rows mapped to their display lines."
  @type render_layer :: %{non_neg_integer() => display_line()}

  # ── Components ─────────────────────────────────────────────────────────────

  defmodule Overlay do
    @moduledoc """
    An overlay popup (picker, which-key, completion menu, hover, signature help)
    with absolute screen coordinates and an optional cursor override.
    """

    alias MingaEditor.DisplayList

    defstruct draws: [], cursor: nil

    @type t :: %__MODULE__{
            draws: [DisplayList.draw()],
            cursor: {non_neg_integer(), non_neg_integer()} | nil
          }
  end

  # ── Draw constructor ───────────────────────────────────────────────────────

  @doc """
  Creates a draw tuple with a Face style.

  ## Examples

      iex> DisplayList.draw(0, 5, "hello")
      {0, 5, "hello", %Face{name: "_"}}

      iex> DisplayList.draw(0, 5, "hello", Face.new(fg: 0xFF0000, bold: true))
      {0, 5, "hello", %Face{name: "_", fg: 0xFF0000, bold: true}}
  """
  @spec draw(non_neg_integer(), non_neg_integer(), String.t(), Face.t()) :: draw()
  def draw(row, col, text, %Face{} = face \\ Face.new())
      when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and is_binary(text) do
    {row, col, text, face}
  end
end

defmodule Minga.Editor.DisplayList do
  @moduledoc """
  BEAM-side display list: a styled text run intermediate representation.

  Sits between editor state and protocol encoding. The renderer produces
  a `Frame` struct containing all visual content, then `to_commands/1`
  converts it to protocol command binaries for the TUI frontend. Other
  frontends (GUI, headless) can consume the frame directly.

  ## Coordinate system

  All coordinates within a `WindowFrame` are **window-relative**: row 0,
  col 0 is the top-left of the window's content rect. The `rect` field
  carries the absolute screen position; `to_commands/1` adds the rect
  offset when generating protocol commands.

  Other frame sections (file_tree, agent_panel, minibuffer, overlays) use
  **absolute screen coordinates** since they're not scoped to a window.

  ## Types

  * `draw()` — a pending draw: `{row, col, text, style}`. This is the
    return type of all renderer modules after the display list refactor.
  * `text_run()` — column + text + style (no row; row is the map key).
  * `display_line()` — a list of text runs for one screen row.
  * `render_layer()` — rows mapped to their display lines.
  """

  alias Minga.Core.Face
  alias Minga.Editor.Layout
  alias Minga.Frontend.Protocol

  # ── Fundamental types ──────────────────────────────────────────────────────

  @typedoc "RGB color as a 24-bit integer (e.g. `0xFF6C6B`)."
  @type color :: non_neg_integer()

  @typedoc "Style: a resolved Face struct."
  @type style :: Face.t()

  @typedoc """
  A pending draw command: `{row, col, text, Face.t()}`.

  This is the intermediate representation that renderer modules produce.
  """
  @type draw :: {non_neg_integer(), non_neg_integer(), String.t(), Face.t()}

  @typedoc "A single styled text span at a specific column."
  @type text_run :: {col :: non_neg_integer(), text :: String.t(), style :: Face.t()}

  @typedoc "All text runs on one screen row."
  @type display_line :: [text_run()]

  @typedoc "Screen rows mapped to their display lines."
  @type render_layer :: %{non_neg_integer() => display_line()}

  # ── Frame components ───────────────────────────────────────────────────────

  defmodule Cursor do
    @moduledoc """
    Cursor state: position and shape as a single unit.

    Used by `WindowFrame` (optional, nil for non-active windows) and
    `Frame` (always present). Bundling position and shape prevents
    them from getting out of sync.
    """

    @enforce_keys [:row, :col, :shape]
    defstruct [:row, :col, :shape]

    @type shape :: :block | :beam | :underline

    @type t :: %__MODULE__{
            row: non_neg_integer(),
            col: non_neg_integer(),
            shape: shape()
          }

    @doc "Creates a cursor at the given position with the given shape."
    @spec new(non_neg_integer(), non_neg_integer(), shape()) :: t()
    def new(row, col, shape) when is_integer(row) and is_integer(col) do
      %__MODULE__{row: row, col: col, shape: shape}
    end
  end

  defmodule WindowFrame do
    @moduledoc """
    Display data for a single editor window.

    Contains gutter, content lines, tilde filler, and modeline data,
    all in window-relative coordinates. The `rect` field gives the
    absolute screen position for `to_commands/1`.
    """

    alias Minga.Editor.DisplayList
    alias Minga.Editor.DisplayList.Cursor
    alias Minga.Editor.Layout
    alias Minga.Editor.SemanticWindow

    @enforce_keys [:rect]
    defstruct rect: nil,
              gutter: %{},
              lines: %{},
              tilde_lines: %{},
              modeline: %{},
              cursor: nil,
              semantic: nil

    @type t :: %__MODULE__{
            rect: Layout.rect(),
            gutter: DisplayList.render_layer(),
            lines: DisplayList.render_layer(),
            tilde_lines: DisplayList.render_layer(),
            modeline: DisplayList.render_layer(),
            cursor: Cursor.t() | nil,
            semantic: SemanticWindow.t() | nil
          }
  end

  defmodule Overlay do
    @moduledoc """
    An overlay popup (picker, which-key, completion menu) with absolute
    screen coordinates and an optional cursor override.
    """

    alias Minga.Editor.DisplayList

    defstruct draws: [], cursor: nil

    @type t :: %__MODULE__{
            draws: [DisplayList.draw()],
            cursor: {non_neg_integer(), non_neg_integer()} | nil
          }
  end

  defmodule Frame do
    @moduledoc """
    Complete display state for one rendered frame.

    Contains all visual content needed to paint the screen. The TUI
    frontend converts this to protocol commands; a GUI frontend could
    convert it to native drawing calls.
    """

    alias Minga.Editor.DisplayList
    alias Minga.Editor.DisplayList.{Cursor, Overlay, WindowFrame}

    @enforce_keys [:cursor]
    defstruct cursor: nil,
              tab_bar: [],
              windows: [],
              file_tree: [],
              agent_panel: [],
              agentic_view: [],
              status_bar: [],
              minibuffer: [],
              separators: [],
              overlays: [],
              regions: [],
              splash: nil,
              title: nil,
              window_bg: nil

    @type t :: %__MODULE__{
            cursor: Cursor.t(),
            tab_bar: [DisplayList.draw()],
            windows: [WindowFrame.t()],
            file_tree: [DisplayList.draw()],
            agent_panel: [DisplayList.draw()],
            agentic_view: [DisplayList.draw()],
            status_bar: [DisplayList.draw()],
            minibuffer: [DisplayList.draw()],
            separators: [DisplayList.draw()],
            overlays: [Overlay.t()],
            regions: [binary()],
            splash: [DisplayList.draw()] | nil,
            title: String.t() | nil,
            window_bg: non_neg_integer() | nil
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

  # ── Layer helpers ──────────────────────────────────────────────────────────

  @doc """
  Groups a list of draws by row into a render layer.

  Each draw's row becomes the map key; the draw is converted to a text_run
  (col, text, style) within that row's display_line.
  """
  @spec draws_to_layer([draw()]) :: render_layer()
  def draws_to_layer(draws) do
    draws
    |> Enum.group_by(fn {row, _, _, _} -> row end)
    |> Map.new(fn {row, row_draws} ->
      runs = Enum.map(row_draws, fn {_, col, text, style} -> {col, text, style} end)
      {row, runs}
    end)
  end

  # ── Draw offsetting ────────────────────────────────────────────────────────

  @doc "Offsets draw tuples by the given row and column amounts."
  @spec offset_draws([draw()], non_neg_integer(), non_neg_integer()) :: [draw()]
  def offset_draws(draws, 0, 0), do: draws

  def offset_draws(draws, row_off, col_off) do
    Enum.map(draws, fn {row, col, text, style} ->
      {row + row_off, col + col_off, text, style}
    end)
  end

  # ── Grayscale dimming (inactive windows) ───────────────────────────────────

  @doc "Converts draw tuples to grayscale (luminance-weighted)."
  @spec grayscale_draws([draw()]) :: [draw()]
  def grayscale_draws(draws) do
    Enum.map(draws, fn {row, col, text, %Face{} = face} ->
      fg = face.fg || 0xFFFFFF
      bg = face.bg || 0x000000

      %{face | fg: grayscale_color(fg), bg: grayscale_color(bg)}
      |> then(fn new_face -> {row, col, text, new_face} end)
    end)
  end

  @spec grayscale_color(non_neg_integer()) :: non_neg_integer()
  defp grayscale_color(rgb) do
    r = Bitwise.band(Bitwise.bsr(rgb, 16), 0xFF)
    g = Bitwise.band(Bitwise.bsr(rgb, 8), 0xFF)
    b = Bitwise.band(rgb, 0xFF)
    gray = round(r * 0.299 + g * 0.587 + b * 0.114)
    Bitwise.bor(Bitwise.bor(Bitwise.bsl(gray, 16), Bitwise.bsl(gray, 8)), gray)
  end

  # ── Frame → protocol commands ──────────────────────────────────────────────

  @doc """
  Converts a frame into a list of protocol command binaries.

  Produces the same output that the old renderer sent to the port:
  clear, regions, content draws, cursor, batch_end.

  Options:
  - `batch_end: false` — omit the trailing `batch_end` command. Used by
    the GUI emit path which appends Metal-critical chrome commands before
    sending `batch_end` to ensure atomic frame delivery.
  """
  @spec to_commands(Frame.t(), keyword()) :: [binary()]
  def to_commands(%Frame{} = frame, opts \\ []) do
    window_draws =
      Enum.flat_map(frame.windows, fn wf ->
        {row_off, col_off, _w, _h} = wf.rect

        # Window-relative draws get offset to absolute screen coordinates
        gutter = layer_to_draws(wf.gutter)
        lines = layer_to_draws(wf.lines)
        tildes = layer_to_draws(wf.tilde_lines)

        offset_draws(gutter ++ lines ++ tildes, row_off, col_off)
      end)

    splash_draws =
      case frame.splash do
        nil -> []
        draws -> draws
      end

    all_draws =
      frame.tab_bar ++
        frame.file_tree ++
        frame.agentic_view ++
        window_draws ++
        frame.separators ++
        frame.status_bar ++
        frame.agent_panel ++
        frame.minibuffer ++
        splash_draws

    overlay_draws = Enum.flat_map(frame.overlays, fn %Overlay{draws: draws} -> draws end)

    tail =
      if Keyword.get(opts, :batch_end, true) do
        [
          Protocol.encode_cursor_shape(frame.cursor.shape),
          Protocol.encode_cursor(frame.cursor.row, frame.cursor.col),
          Protocol.encode_batch_end()
        ]
      else
        [
          Protocol.encode_cursor_shape(frame.cursor.shape),
          Protocol.encode_cursor(frame.cursor.row, frame.cursor.col)
        ]
      end

    [Protocol.encode_clear()] ++
      frame.regions ++
      draws_to_commands(all_draws) ++
      draws_to_commands(overlay_draws) ++
      tail
  end

  @doc """
  Converts a list of draw tuples to protocol command binaries.

  Uses `encode_draw_smart/4` which automatically selects the compact
  `draw_text` opcode for simple styles (fg/bg/bold/italic/underline/reverse)
  or the extended `draw_styled_text` opcode when the style includes
  strikethrough, underline_style, underline_color, or blend.
  """
  @spec draws_to_commands([draw()]) :: [binary()]
  def draws_to_commands(draws) do
    Enum.flat_map(draws, fn {row, col, text, %Face{} = face} ->
      style = Face.to_style(face)
      {style, registration_cmds} = resolve_font_family(style)
      registration_cmds ++ [Protocol.encode_draw_smart(row, col, text, style)]
    end)
  end

  # Resolves font_family in a style keyword list to a font_id.
  # Uses the font registry from the process dictionary (set by Emit).
  # Returns {updated_style, [register_font_commands]}.
  @spec resolve_font_family(keyword()) :: {keyword(), [binary()]}
  defp resolve_font_family(style) do
    case Keyword.pop(style, :font_family) do
      {nil, _} ->
        {style, []}

      {family, rest} ->
        registry = Process.get(:emit_font_registry) || Minga.UI.FontRegistry.new()

        {font_id, updated_registry, new?} =
          Minga.UI.FontRegistry.get_or_register(registry, family)

        Process.put(:emit_font_registry, updated_registry)

        style_with_id = if font_id > 0, do: [{:font_id, font_id} | rest], else: rest
        reg_cmds = if new?, do: [Protocol.encode_register_font(font_id, family)], else: []
        {style_with_id, reg_cmds}
    end
  end

  # ── Layer ↔ draws ──────────────────────────────────────────────────────────

  @doc "Flattens a render layer back into a list of draw tuples."
  @spec layer_to_draws(render_layer()) :: [draw()]
  def layer_to_draws(layer) when is_map(layer) do
    Enum.flat_map(layer, fn {row, runs} ->
      Enum.map(runs, fn {col, text, style} -> {row, col, text, style} end)
    end)
  end

  # ── Frame diffing (structural support) ─────────────────────────────────────

  @doc """
  Compares two render layers line-by-line and returns the set of changed rows.

  This enables incremental rendering: only rows that differ between
  frames need to be re-sent to the frontend.
  """
  @spec changed_rows(render_layer(), render_layer()) :: MapSet.t(non_neg_integer())
  def changed_rows(old_layer, new_layer) do
    all_rows = MapSet.union(MapSet.new(Map.keys(old_layer)), MapSet.new(Map.keys(new_layer)))

    Enum.reduce(all_rows, MapSet.new(), fn row, acc ->
      old_line = Map.get(old_layer, row, [])
      new_line = Map.get(new_layer, row, [])

      if old_line == new_line do
        acc
      else
        MapSet.put(acc, row)
      end
    end)
  end
end

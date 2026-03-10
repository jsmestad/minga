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

  alias Minga.Editor.Layout
  alias Minga.Port.Protocol

  # ── Fundamental types ──────────────────────────────────────────────────────

  @typedoc "RGB color as a 24-bit integer (e.g. `0xFF6C6B`)."
  @type color :: non_neg_integer()

  @typedoc "Style attributes as a keyword list, matching `Protocol.style()`."
  @type style :: keyword()

  @typedoc """
  A pending draw command: `{row, col, text, style}`.

  This is the intermediate representation that renderer modules produce.
  Replaces `Protocol.encode_draw` in the rendering pipeline.
  """
  @type draw :: {non_neg_integer(), non_neg_integer(), String.t(), style()}

  @typedoc "A single styled text span at a specific column."
  @type text_run :: {col :: non_neg_integer(), text :: String.t(), style :: style()}

  @typedoc "All text runs on one screen row."
  @type display_line :: [text_run()]

  @typedoc "Screen rows mapped to their display lines."
  @type render_layer :: %{non_neg_integer() => display_line()}

  # ── Frame components ───────────────────────────────────────────────────────

  defmodule WindowFrame do
    @moduledoc """
    Display data for a single editor window.

    Contains gutter, content lines, tilde filler, and modeline data,
    all in window-relative coordinates. The `rect` field gives the
    absolute screen position for `to_commands/1`.
    """

    alias Minga.Editor.DisplayList
    alias Minga.Editor.Layout

    @enforce_keys [:rect]
    defstruct rect: nil,
              gutter: %{},
              lines: %{},
              tilde_lines: %{},
              modeline: %{},
              cursor: nil

    @type t :: %__MODULE__{
            rect: Layout.rect(),
            gutter: DisplayList.render_layer(),
            lines: DisplayList.render_layer(),
            tilde_lines: DisplayList.render_layer(),
            modeline: DisplayList.render_layer(),
            cursor: {non_neg_integer(), non_neg_integer()} | nil
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
    alias Minga.Editor.DisplayList.{Overlay, WindowFrame}

    @enforce_keys [:cursor, :cursor_shape]
    defstruct cursor: {0, 0},
              cursor_shape: :block,
              tab_bar: [],
              windows: [],
              file_tree: [],
              agent_panel: [],
              agentic_view: [],
              minibuffer: [],
              separators: [],
              overlays: [],
              regions: [],
              splash: nil,
              title: nil,
              window_bg: nil

    @type t :: %__MODULE__{
            cursor: {non_neg_integer(), non_neg_integer()},
            cursor_shape: :block | :beam | :underline,
            tab_bar: [DisplayList.draw()],
            windows: [WindowFrame.t()],
            file_tree: [DisplayList.draw()],
            agent_panel: [DisplayList.draw()],
            agentic_view: [DisplayList.draw()],
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
  Creates a draw tuple. Drop-in replacement for `Protocol.encode_draw/4`.

  ## Examples

      iex> DisplayList.draw(0, 5, "hello")
      {0, 5, "hello", []}

      iex> DisplayList.draw(0, 5, "hello", fg: 0xFF0000, bold: true)
      {0, 5, "hello", [fg: 0xFF0000, bold: true]}
  """
  @spec draw(non_neg_integer(), non_neg_integer(), String.t(), style()) :: draw()
  def draw(row, col, text, style \\ [])
      when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and is_binary(text) do
    {row, col, text, style}
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
    Enum.map(draws, fn {row, col, text, style} ->
      fg = Keyword.get(style, :fg, 0xFFFFFF)
      bg = Keyword.get(style, :bg, 0x000000)

      fg_gray = grayscale_color(fg)
      bg_gray = grayscale_color(bg)

      new_style =
        style
        |> Keyword.put(:fg, fg_gray)
        |> Keyword.put(:bg, bg_gray)

      {row, col, text, new_style}
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
  """
  @spec to_commands(Frame.t()) :: [binary()]
  def to_commands(%Frame{} = frame) do
    window_draws =
      Enum.flat_map(frame.windows, fn wf ->
        {row_off, col_off, _w, _h} = wf.rect

        # Window-relative draws get offset to absolute screen coordinates
        gutter = layer_to_draws(wf.gutter)
        lines = layer_to_draws(wf.lines)
        tildes = layer_to_draws(wf.tilde_lines)
        modeline = layer_to_draws(wf.modeline)

        offset_draws(gutter ++ lines ++ tildes ++ modeline, row_off, col_off)
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
        frame.agent_panel ++
        frame.minibuffer ++
        splash_draws

    overlay_draws = Enum.flat_map(frame.overlays, fn %Overlay{draws: draws} -> draws end)

    [Protocol.encode_clear()] ++
      frame.regions ++
      draws_to_commands(all_draws) ++
      draws_to_commands(overlay_draws) ++
      [
        Protocol.encode_cursor_shape(frame.cursor_shape),
        Protocol.encode_cursor(elem(frame.cursor, 0), elem(frame.cursor, 1)),
        Protocol.encode_batch_end()
      ]
  end

  @doc "Converts a list of draw tuples to protocol command binaries."
  @spec draws_to_commands([draw()]) :: [binary()]
  def draws_to_commands(draws) do
    Enum.map(draws, fn {row, col, text, style} ->
      Protocol.encode_draw(row, col, text, style)
    end)
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

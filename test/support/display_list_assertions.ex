defmodule Minga.Test.DisplayListAssertions do
  @moduledoc """
  Assertion helpers for display list IR testing.

  Tests use these to verify rendering at the Frame/WindowFrame level,
  decoupled from chrome layout changes. Content tests survive
  modeline/tab bar/gutter changes.

  ## Usage

      import Minga.Test.DisplayListAssertions

      test "buffer content renders in window" do
        state = base_state(content: "hello world")
        frame = render_frame(state)
        window = hd(frame.windows)

        assert_window_contains(window, "hello world")
      end
  """

  import ExUnit.Assertions

  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Frame, WindowFrame}
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Compose
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState

  # ── Frame rendering ───────────────────────────────────────────────────────

  @doc """
  Runs the render pipeline from state to Frame without emitting to any port.

  Uses Layout -> Scroll -> Content -> Chrome -> Compose stages.
  Returns a complete `Frame` struct suitable for assertion helpers.
  """
  @spec render_frame(EditorState.t()) :: Frame.t()
  def render_frame(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {buffer_frames, cursor_info, state} = Content.build_content(state, scrolls)

    {agent_chat_frames, agent_cursor, state} =
      Content.build_agent_chat_content(state, layout)

    cursor_info = if agent_cursor != nil, do: agent_cursor, else: cursor_info
    window_frames = buffer_frames ++ agent_chat_frames

    chrome = state.shell.build_chrome(state, layout, scrolls, cursor_info)
    Compose.compose_windows(window_frames, chrome, cursor_info, state)
  end

  # ── Text extraction ───────────────────────────────────────────────────────

  @doc """
  Extracts all text from a WindowFrame's content lines (not gutter, not modeline).

  Returns a list of strings, one per visible row. Each string is the
  concatenation of all text runs on that row, sorted by column.
  Rows with no content are omitted.
  """
  @spec window_content_text(WindowFrame.t()) :: [{non_neg_integer(), String.t()}]
  def window_content_text(%WindowFrame{lines: lines, tilde_lines: tildes}) do
    lines
    |> Map.merge(tildes, fn _row, line_runs, _tilde_runs -> line_runs end)
    |> layer_to_text()
  end

  @doc """
  Extracts text from a WindowFrame's gutter.

  Returns a list of strings, one per visible row.
  """
  @spec window_gutter_text(WindowFrame.t()) :: [{non_neg_integer(), String.t()}]
  def window_gutter_text(%WindowFrame{gutter: gutter}) do
    layer_to_text(gutter)
  end

  @doc """
  Finds draws in a frame section matching a text pattern.

  `section` is one of `:tab_bar`, `:minibuffer`, `:status_bar`,
  `:file_tree`, or `:agent_panel`.

  `pattern` can be a plain string (substring match) or a `Regex`.
  Returns all matching draw tuples.
  """
  @spec find_draws(Frame.t(), atom(), String.t() | Regex.t()) :: [DisplayList.draw()]
  def find_draws(%Frame{} = frame, section, pattern) do
    draws = section_draws(frame, section)
    Enum.filter(draws, &draw_matches?(&1, pattern))
  end

  # ── Assertion macros ──────────────────────────────────────────────────────

  @doc """
  Asserts a window contains expected text on a given row (0-indexed within the window).

  The row index refers to the content area only (excludes gutter).
  """
  defmacro assert_window_has_text(window_frame, row, expected_text) do
    quote do
      wf = unquote(window_frame)
      row = unquote(row)
      expected = unquote(expected_text)
      text_lines = Minga.Test.DisplayListAssertions.window_content_text(wf)

      row_text =
        Enum.find(text_lines, fn {r, _text} -> r == row end)
        |> case do
          {_r, text} -> text
          nil -> ""
        end

      assert String.contains?(row_text, expected),
             "Expected window row #{row} to contain #{inspect(expected)}, got: #{inspect(row_text)}\nAll rows: #{inspect(text_lines)}"
    end
  end

  @doc """
  Asserts a window contains text matching a pattern anywhere in its content.

  `pattern` can be a plain string or a `Regex`.
  """
  defmacro assert_window_contains(window_frame, pattern) do
    quote do
      wf = unquote(window_frame)
      pattern = unquote(pattern)
      text_lines = Minga.Test.DisplayListAssertions.window_content_text(wf)
      all_text = Enum.map(text_lines, fn {_row, text} -> text end)

      found =
        Enum.any?(all_text, fn text ->
          Minga.Test.DisplayListAssertions.text_matches?(text, pattern)
        end)

      assert found,
             "Expected window content to contain #{inspect(pattern)}, got rows: #{inspect(all_text)}"
    end
  end

  @doc """
  Asserts frame cursor position and shape.
  """
  defmacro assert_frame_cursor(frame, row, col, shape) do
    quote do
      f = unquote(frame)
      expected_row = unquote(row)
      expected_col = unquote(col)
      expected_shape = unquote(shape)

      assert %MingaEditor.DisplayList.Cursor{} = f.cursor,
             "Expected frame to have a cursor"

      assert f.cursor.row == expected_row,
             "Expected cursor row #{expected_row}, got #{f.cursor.row}"

      assert f.cursor.col == expected_col,
             "Expected cursor col #{expected_col}, got #{f.cursor.col}"

      assert f.cursor.shape == expected_shape,
             "Expected cursor shape #{inspect(expected_shape)}, got #{inspect(f.cursor.shape)}"
    end
  end

  @doc """
  Asserts the status bar contains text matching the given string or regex.
  """
  defmacro assert_status_bar_contains(frame, text) do
    quote do
      f = unquote(frame)
      pattern = unquote(text)
      draws = Minga.Test.DisplayListAssertions.section_draws(f, :status_bar)
      all_text = Minga.Test.DisplayListAssertions.draws_to_text(draws)

      assert Minga.Test.DisplayListAssertions.text_matches?(all_text, pattern),
             "Expected status bar to contain #{inspect(pattern)}, got: #{inspect(all_text)}"
    end
  end

  @doc """
  Asserts the tab bar contains text matching the given string or regex.
  """
  defmacro assert_tab_bar_contains(frame, text) do
    quote do
      f = unquote(frame)
      pattern = unquote(text)
      draws = Minga.Test.DisplayListAssertions.section_draws(f, :tab_bar)
      all_text = Minga.Test.DisplayListAssertions.draws_to_text(draws)

      assert Minga.Test.DisplayListAssertions.text_matches?(all_text, pattern),
             "Expected tab bar to contain #{inspect(pattern)}, got: #{inspect(all_text)}"
    end
  end

  @doc """
  Asserts the minibuffer contains text matching the given string or regex.
  """
  defmacro assert_minibuffer_contains(frame, text) do
    quote do
      f = unquote(frame)
      pattern = unquote(text)
      draws = Minga.Test.DisplayListAssertions.section_draws(f, :minibuffer)
      all_text = Minga.Test.DisplayListAssertions.draws_to_text(draws)

      assert Minga.Test.DisplayListAssertions.text_matches?(all_text, pattern),
             "Expected minibuffer to contain #{inspect(pattern)}, got: #{inspect(all_text)}"
    end
  end

  # ── Public helpers (used by macros) ───────────────────────────────────────

  @doc """
  Returns the draw list for a given frame section.
  """
  @spec section_draws(Frame.t(), atom()) :: [DisplayList.draw()]
  def section_draws(%Frame{} = frame, :tab_bar), do: frame.tab_bar
  def section_draws(%Frame{} = frame, :minibuffer), do: frame.minibuffer
  def section_draws(%Frame{} = frame, :status_bar), do: frame.status_bar
  def section_draws(%Frame{} = frame, :file_tree), do: frame.file_tree
  def section_draws(%Frame{} = frame, :agent_panel), do: frame.agent_panel

  @doc """
  Concatenates all text from a list of draw tuples into a single string.

  Draws are sorted by row then column before concatenation.
  """
  @spec draws_to_text([DisplayList.draw()]) :: String.t()
  def draws_to_text(draws) do
    draws
    |> Enum.sort_by(fn {row, col, _text, _style} -> {row, col} end)
    |> Enum.map_join(fn {_row, _col, text, _style} -> text end)
  end

  @doc """
  Tests whether text matches a pattern (string or regex).
  """
  @spec text_matches?(String.t(), String.t() | Regex.t()) :: boolean()
  def text_matches?(text, %Regex{} = regex), do: Regex.match?(regex, text)
  def text_matches?(text, pattern) when is_binary(pattern), do: String.contains?(text, pattern)

  # ── Private helpers ───────────────────────────────────────────────────────

  # Converts a render layer to a list of {row, text} pairs, sorted by row.
  @spec layer_to_text(DisplayList.render_layer()) :: [{non_neg_integer(), String.t()}]
  defp layer_to_text(layer) when is_map(layer) do
    layer
    |> Enum.sort_by(fn {row, _runs} -> row end)
    |> Enum.map(fn {row, runs} ->
      text =
        runs
        |> Enum.sort_by(fn {col, _text, _style} -> col end)
        |> Enum.map_join(fn {_col, text, _style} -> text end)

      {row, text}
    end)
  end

  @spec draw_matches?(DisplayList.draw(), String.t() | Regex.t()) :: boolean()
  defp draw_matches?({_row, _col, text, _style}, %Regex{} = regex), do: Regex.match?(regex, text)

  defp draw_matches?({_row, _col, text, _style}, pattern) when is_binary(pattern),
    do: String.contains?(text, pattern)
end

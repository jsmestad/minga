defmodule Minga.Agent.View.RendererTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.Renderer
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Input
  alias Minga.Theme

  defp base_state(opts \\ []) do
    rows = Keyword.get(opts, :rows, 40)
    cols = Keyword.get(opts, :cols, 120)
    {:ok, buf} = BufferServer.start_link(content: "line one\nline two\nline three")

    input_lines = Keyword.get(opts, :input_lines, [Keyword.get(opts, :input_text, "")])

    input_cursor =
      Keyword.get(opts, :input_cursor, {0, String.length(Keyword.get(opts, :input_text, ""))})

    {:ok, prompt_buf} = BufferServer.start_link(content: Enum.join(input_lines, "\n"))
    BufferServer.set_cursor(prompt_buf, input_cursor)

    panel = %PanelState{
      visible: true,
      input_focused: Keyword.get(opts, :input_focused, false),
      prompt_buffer: prompt_buf,
      scroll: Minga.Scroll.new(),
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium"
    }

    agent = %AgentState{
      session: nil,
      status: :idle,
      panel: panel,
      error: nil,
      spinner_timer: nil,
      buffer: nil
    }

    preview_opt = Keyword.get(opts, :preview, nil)

    agentic = %ViewState{
      active: true,
      focus: Keyword.get(opts, :focus, :chat),
      preview: preview_opt || Preview.new(),
      saved_windows: nil,
      pending_prefix: nil,
      saved_file_tree: nil
    }

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(rows, cols),
      vim: VimState.new(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      focus_stack: Input.default_stack(),
      agent: agent,
      agentic: agentic,
      theme: Theme.get!(:doom_one),
      highlight: %Highlighting{}
    }
  end

  # Computes content_rect and sidebar_rect from state, matching
  # what the render pipeline's compute_agent_sidebar/2 does.
  # Content starts at row 0, col 0 (no title bar or modeline; those
  # are chrome layer concerns).
  @spec sidebar_rects(EditorState.t()) ::
          {Minga.Editor.Layout.rect(), Minga.Editor.Layout.rect()}
  defp sidebar_rects(state) do
    cols = state.viewport.cols
    rows = state.viewport.rows
    chat_width = max(div(cols * state.agentic.chat_width_pct, 100), 20)
    sidebar_col = chat_width + 1
    sidebar_width = max(cols - chat_width - 1, 10)

    {{0, 0, chat_width, rows}, {0, sidebar_col, sidebar_width, rows}}
  end

  # Convenience: render with sidebar using production-like rects.
  @spec render_sidebar(EditorState.t()) :: [Minga.Editor.DisplayList.draw()]
  defp render_sidebar(state) do
    {content_rect, sidebar_rect} = sidebar_rects(state)
    Renderer.render_with_sidebar(state, content_rect, sidebar_rect)
  end

  describe "render_with_sidebar/3" do
    test "returns a non-empty list of draw tuples" do
      state = base_state(rows: 30, cols: 100)
      commands = render_sidebar(state)
      assert [_ | _] = commands
      assert Enum.all?(commands, &is_tuple/1)
    end

    test "all draw tuples have valid 4-element structure" do
      state = base_state(rows: 30, cols: 100)
      commands = render_sidebar(state)

      Enum.each(commands, fn cmd ->
        assert tuple_size(cmd) == 4, "draw tuple should have 4 elements: #{inspect(cmd)}"
        {row, col, text, style} = cmd
        assert is_integer(row)
        assert is_integer(col)
        assert is_binary(text)
        assert is_list(style)
      end)
    end

    test "produces more commands with more rows (larger viewport)" do
      state_small = base_state(rows: 20, cols: 80)
      state_large = base_state(rows: 40, cols: 80)

      cmds_small = render_sidebar(state_small)
      cmds_large = render_sidebar(state_large)

      assert length(cmds_large) > length(cmds_small)
    end

    test "does not crash when active buffer is nil" do
      state = base_state()
      state = put_in(state.buffers.active, nil)
      commands = render_sidebar(state)
      assert is_list(commands)
    end

    test "renders with file viewer scroll applied" do
      state_top = base_state(viewer_scroll: 0)
      state_scrolled = base_state(viewer_scroll: 2)

      cmds_top = render_sidebar(state_top)
      cmds_scrolled = render_sidebar(state_scrolled)

      assert is_list(cmds_top)
      assert is_list(cmds_scrolled)
    end
  end

  describe "render_in_rect/2" do
    test "returns a non-empty list of draw tuples" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render_in_rect(state, {0, 0, 80, 30})
      assert [_ | _] = commands
      assert Enum.all?(commands, &is_tuple/1)
    end

    test "compact mode has no column separator or sidebar content" do
      cols = 100
      state = base_state(rows: 30, cols: cols)
      chat_width = div(cols * 65, 100)
      commands = Renderer.render_in_rect(state, {0, 0, chat_width, 30})

      # No draw commands should appear past the chat width (no sidebar column)
      sidebar_cmds =
        Enum.filter(commands, fn {_r, col, _text, _s} -> col > chat_width end)

      assert sidebar_cmds == [], "compact mode should not have sidebar content"
    end
  end

  describe "layout proportions" do
    test "chat panel occupies ~65% of columns" do
      cols = 120
      state = base_state(cols: cols)

      expected_chat_width = div(cols * 65, 100)
      commands = render_sidebar(state)

      chat_cols =
        commands
        |> Enum.map(fn {_row, col, _text, _style} -> col end)
        |> Enum.filter(&(&1 < expected_chat_width))

      viewer_cols =
        commands
        |> Enum.map(fn {_row, col, _text, _style} -> col end)
        |> Enum.filter(&(&1 > expected_chat_width))

      assert chat_cols != [], "expected draw commands in chat panel columns"
      assert viewer_cols != [], "expected draw commands in viewer panel columns"
    end
  end

  describe "input area inside left column" do
    test "input border renders at col 0 within the left panel" do
      state = base_state(rows: 30, cols: 100)
      commands = render_sidebar(state)

      # Input box should have a top border starting at col 0
      input_cmds =
        Enum.filter(commands, fn {_row, col, text, _style} ->
          col == 0 and String.starts_with?(text, "╭─ Prompt")
        end)

      assert input_cmds != [], "expected input border at col 0"
    end

    test "input box width is constrained to left column (chat_width)" do
      cols = 100
      state = base_state(rows: 30, cols: cols)
      commands = render_sidebar(state)

      chat_width = div(cols * 65, 100)

      top_border_cmds =
        Enum.filter(commands, fn {_row, col, text, _style} ->
          col == 0 and String.starts_with?(text, "╭─ Prompt")
        end)

      assert [top_cmd | _] = top_border_cmds
      {_row, _col, top_text, _style} = top_cmd

      assert String.length(top_text) <= chat_width,
             "input box should be ≤ chat_width (#{chat_width}), got #{String.length(top_text)}"
    end

    test "right panel extends alongside the input area" do
      cols = 100
      state = base_state(rows: 30, cols: cols)
      commands = render_sidebar(state)

      chat_width = div(cols * 65, 100)
      viewer_col = chat_width + 1

      # Find the input box top border row
      input_row =
        commands
        |> Enum.find(fn {_r, col, text, _s} ->
          col == 0 and String.starts_with?(text, "╭─ Prompt")
        end)
        |> elem(0)

      # The viewer/dashboard should have draw commands at rows alongside the input
      viewer_at_input_rows =
        Enum.filter(commands, fn {row, col, _text, _style} ->
          row >= input_row and col >= viewer_col
        end)

      assert viewer_at_input_rows != [],
             "expected right panel content at rows alongside the input area"
    end

    test "separator extends the full panel height" do
      cols = 100
      rows = 30
      state = base_state(rows: rows, cols: cols)
      commands = render_sidebar(state)

      chat_width = div(cols * 65, 100)

      sep_cmds =
        Enum.filter(commands, fn {_row, col, text, _style} ->
          col == chat_width and text == "│"
        end)

      sep_rows = Enum.map(sep_cmds, fn {row, _, _, _} -> row end) |> Enum.sort()

      # Separator should span the full height of the content rect
      expected_rows = Enum.to_list(0..(rows - 1))

      assert sep_rows == expected_rows,
             "separator should span rows 0..#{rows - 1}, got #{inspect(sep_rows)}"
    end
  end

  describe "file viewer header" do
    test "file viewer header is at the top of the viewer panel" do
      state = base_state(rows: 30, cols: 100)
      commands = render_sidebar(state)

      chat_width = div(100 * 65, 100)
      viewer_col = chat_width + 1

      # Header should be at row 0 (top of content rect), at viewer_col
      header_cmds =
        Enum.filter(commands, fn {row, col, _text, _style} ->
          row == 0 and col >= viewer_col
        end)

      assert header_cmds != [], "expected file viewer header at the top of the viewer panel"
    end
  end

  describe "cursor_position_in_rect/2" do
    test "returns nil when input is not focused" do
      state = base_state(rows: 40, input_focused: false)
      assert Renderer.cursor_position_in_rect(state, {0, 0, 80, 40}) == nil
    end

    test "returns {row, col} when input is focused" do
      state = base_state(rows: 40, input_focused: true)
      result = Renderer.cursor_position_in_rect(state, {0, 0, 80, 40})

      assert {row, col} = result
      assert is_integer(row)
      assert is_integer(col)
      assert row >= 0 and row < 40
      assert col >= 0
    end

    test "cursor column advances with input text length" do
      state_empty = base_state(input_focused: true, input_text: "")
      state_hello = base_state(input_focused: true, input_text: "hello")

      {_r, col_empty} = Renderer.cursor_position_in_rect(state_empty, {0, 0, 80, 40})
      {_r, col_hello} = Renderer.cursor_position_in_rect(state_hello, {0, 0, 80, 40})

      assert col_hello == col_empty + String.length("hello")
    end

    test "cursor row is the same regardless of short input text" do
      state_short = base_state(input_focused: true, input_text: "hi")
      state_long = base_state(input_focused: true, input_text: "a long message here")

      {row_short, _} = Renderer.cursor_position_in_rect(state_short, {0, 0, 80, 40})
      {row_long, _} = Renderer.cursor_position_in_rect(state_long, {0, 0, 80, 40})

      assert row_short == row_long
    end

    test "cursor position is offset by the rect origin" do
      state = base_state(rows: 40, input_focused: true, input_text: "test")

      {row_origin, _col_origin} = Renderer.cursor_position_in_rect(state, {0, 0, 80, 40})
      {row_offset, _col_offset} = Renderer.cursor_position_in_rect(state, {5, 0, 80, 40})

      assert row_offset == row_origin + 5
    end
  end

  describe "resize re-layout" do
    test "different viewport sizes produce different chat widths" do
      state_80 = base_state(rows: 24, cols: 80)
      state_120 = base_state(rows: 24, cols: 120)

      cmds_80 = render_sidebar(state_80)
      cmds_120 = render_sidebar(state_120)

      cols_80 =
        cmds_80
        |> Enum.map(fn {_row, col, _text, _style} -> col end)
        |> Enum.max(fn -> 0 end)

      cols_120 =
        cmds_120
        |> Enum.map(fn {_row, col, _text, _style} -> col end)
        |> Enum.max(fn -> 0 end)

      assert cols_120 > cols_80, "wider viewport should use more columns"
    end
  end

  describe "model info" do
    test "model name appears near input area" do
      state = base_state()
      commands = render_sidebar(state)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "claude-sonnet-4"))
    end

    test "thinking level appears when set" do
      state = base_state()
      commands = render_sidebar(state)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "medium"))
    end

    test "provider name appears in model info line (titleized)" do
      state = base_state()
      commands = render_sidebar(state)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "Anthropic"))
    end
  end

  describe "input box border" do
    test "input area has rounded box border with Prompt label" do
      state = base_state()
      commands = render_sidebar(state)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.starts_with?(&1, "╭─ Prompt")),
             "expected top border with Prompt label"

      assert Enum.any?(texts, &String.starts_with?(&1, "╰─")),
             "expected bottom border"

      refute Enum.any?(texts, &String.contains?(&1, "─── Prompt")),
             "should not have old Prompt border"
    end

    test "model info is embedded in bottom border" do
      state = base_state()
      commands = render_sidebar(state)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, fn text ->
               String.starts_with?(text, "╰─") and String.contains?(text, "Claude Sonnet 4")
             end),
             "expected model info in bottom border"
    end
  end

  describe "dashboard panel" do
    test "shows session info when preview is empty" do
      state = base_state()
      commands = render_sidebar(state)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "Context"))
      assert Enum.any?(texts, &String.contains?(&1, "Model"))
      assert Enum.any?(texts, &String.contains?(&1, "claude-sonnet-4"))
    end

    test "shows working directory" do
      state = base_state()
      commands = render_sidebar(state)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "Directory"))
    end

    test "shows LSP section with no servers when list is empty" do
      state = base_state()
      commands = render_sidebar(state)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "LSP"))
      assert Enum.any?(texts, &String.contains?(&1, "No servers active"))
    end

    test "not shown when preview has file content" do
      preview =
        Preview.set_file(
          Preview.new(),
          "/tmp/test.txt",
          "hello world"
        )

      state = base_state(preview: preview)
      commands = render_sidebar(state)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "test.txt"))
    end
  end
end

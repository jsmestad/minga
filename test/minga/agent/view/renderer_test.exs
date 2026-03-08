defmodule Minga.Agent.View.RendererTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Renderer
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.Viewport
  alias Minga.Input
  alias Minga.Mode
  alias Minga.Theme

  defp base_state(opts \\ []) do
    rows = Keyword.get(opts, :rows, 40)
    cols = Keyword.get(opts, :cols, 120)
    {:ok, buf} = BufferServer.start_link(content: "line one\nline two\nline three")

    panel = %PanelState{
      visible: true,
      input_focused: Keyword.get(opts, :input_focused, false),
      input_text: Keyword.get(opts, :input_text, ""),
      scroll_offset: 0,
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

    agentic = %ViewState{
      active: true,
      focus: Keyword.get(opts, :focus, :chat),
      file_viewer_scroll: Keyword.get(opts, :viewer_scroll, 0),
      saved_windows: nil,
      pending_prefix: nil,
      saved_file_tree: nil
    }

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(rows, cols),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      focus_stack: Input.default_stack(),
      agent: agent,
      agentic: agentic,
      theme: Theme.get!(:doom_one),
      highlight: %Highlighting{}
    }
  end

  describe "cursor_position/1" do
    test "when input not focused, cursor is off-screen (row = viewport rows)" do
      state = base_state(rows: 40, input_focused: false)
      {row, _col} = Renderer.cursor_position(state)
      assert row == 40
    end

    test "when input is focused, cursor row is within content area" do
      state = base_state(rows: 40, input_focused: true)
      {row, col} = Renderer.cursor_position(state)
      assert row < 40
      assert row >= 0
      assert col >= 0
    end

    test "cursor column advances with input_text length" do
      state_empty = base_state(input_focused: true, input_text: "")
      state_hello = base_state(input_focused: true, input_text: "hello")

      {_r, col_empty} = Renderer.cursor_position(state_empty)
      {_r, col_hello} = Renderer.cursor_position(state_hello)

      assert col_hello == col_empty + String.length("hello")
    end

    test "cursor row is the same regardless of input text length" do
      state_short = base_state(input_focused: true, input_text: "hi")
      state_long = base_state(input_focused: true, input_text: "a long message here")

      {row_short, _} = Renderer.cursor_position(state_short)
      {row_long, _} = Renderer.cursor_position(state_long)

      assert row_short == row_long
    end
  end

  describe "render/1" do
    test "returns a non-empty list of draw tuples" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)
      assert [_ | _] = commands
      assert Enum.all?(commands, &is_tuple/1)
    end

    test "all draw tuples have valid 4-element structure" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)

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

      cmds_small = Renderer.render(state_small)
      cmds_large = Renderer.render(state_large)

      assert length(cmds_large) > length(cmds_small)
    end

    test "does not crash when active buffer is nil" do
      state = base_state()
      state = put_in(state.buffers.active, nil)
      commands = Renderer.render(state)
      assert is_list(commands)
    end

    test "renders with file viewer scroll applied" do
      state_top = base_state(viewer_scroll: 0)
      state_scrolled = base_state(viewer_scroll: 2)

      cmds_top = Renderer.render(state_top)
      cmds_scrolled = Renderer.render(state_scrolled)

      assert is_list(cmds_top)
      assert is_list(cmds_scrolled)
    end
  end

  describe "layout proportions" do
    test "chat panel occupies ~65% of columns" do
      cols = 120
      state = base_state(cols: cols)

      expected_chat_width = div(cols * 65, 100)

      commands = Renderer.render(state)

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

  describe "title bar" do
    test "renders draw commands at row 0" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)

      row_0_cmds = Enum.filter(commands, fn {row, _col, _text, _style} -> row == 0 end)

      assert row_0_cmds != [], "expected draw commands at row 0 (title bar)"
    end
  end

  describe "full-width input area" do
    test "input area renders at columns starting from 0" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)

      # The input border should be at col 0 near the bottom
      rows = state.viewport.rows
      input_border_row = rows - 1 - 1 - 3

      input_cmds =
        Enum.filter(commands, fn {row, col, _text, _style} ->
          row == input_border_row and col == 0
        end)

      assert input_cmds != [], "expected input border at col 0"
    end
  end

  describe "file viewer header" do
    test "file viewer header is at the top of the viewer panel (row 1)" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)

      chat_width = div(100 * 65, 100)
      viewer_col = chat_width + 1

      # Header should be at row 1 (panel_start), at viewer_col
      header_cmds =
        Enum.filter(commands, fn {row, col, _text, _style} ->
          row == 1 and col == viewer_col
        end)

      assert header_cmds != [], "expected file viewer header at row 1"
    end
  end

  describe "render/1 with RenderInput (isolated, no GenServer)" do
    test "renders with a focused RenderInput, no full EditorState needed" do
      input = %Renderer.RenderInput{
        viewport: Viewport.new(30, 100),
        theme: Theme.get!(:doom_one),
        agent_status: :idle,
        panel: %{
          input_focused: false,
          input_text: "",
          scroll_offset: 0,
          spinner_frame: 0,
          model_name: "claude-sonnet-4",
          thinking_level: "medium",
          auto_scroll: true
        },
        agentic: %{
          chat_width_pct: 65,
          file_viewer_scroll: 0
        },
        messages: [],
        usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
        buffer_snapshot: nil,
        highlight: nil,
        mode: :normal,
        mode_state: nil,
        buf_index: 1,
        buf_count: 1
      }

      commands = Renderer.render(input)
      assert [_ | _] = commands
      assert Enum.all?(commands, &is_tuple/1)
    end

    test "renders with buffer snapshot data" do
      input = %Renderer.RenderInput{
        viewport: Viewport.new(30, 100),
        theme: Theme.get!(:doom_one),
        agent_status: :thinking,
        panel: %{
          input_focused: true,
          input_text: "hello",
          scroll_offset: 0,
          spinner_frame: 3,
          model_name: "claude-sonnet-4",
          thinking_level: "medium",
          auto_scroll: true
        },
        agentic: %{
          chat_width_pct: 65,
          file_viewer_scroll: 0
        },
        messages: [],
        usage: %{input: 1500, output: 300, cache_read: 0, cache_write: 0, cost: 0.012},
        buffer_snapshot: %{
          lines: ["line one", "line two"],
          line_count: 2,
          first_line_byte_offset: 0,
          name: "test.ex"
        },
        highlight: nil,
        mode: :normal,
        mode_state: nil,
        buf_index: 1,
        buf_count: 2
      }

      commands = Renderer.render(input)
      assert [_ | _] = commands

      # Should have file viewer content
      texts = Enum.map(commands, fn {_r, _c, text, _s} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "test.ex"))
    end
  end

  describe "resize re-layout" do
    test "different viewport sizes produce different chat widths" do
      state_80 = base_state(rows: 24, cols: 80)
      state_120 = base_state(rows: 24, cols: 120)

      cmds_80 = Renderer.render(state_80)
      cmds_120 = Renderer.render(state_120)

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
end

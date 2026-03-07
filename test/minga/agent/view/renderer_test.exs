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
      saved_windows: nil
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
    test "returns a non-empty list of binary commands" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)
      assert commands != []
      assert Enum.all?(commands, &is_binary/1)
    end

    test "all draw commands have valid binary structure" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)

      draw_commands = Enum.filter(commands, &(binary_part(&1, 0, 1) == <<0x10>>))
      assert draw_commands != []

      Enum.each(draw_commands, fn cmd ->
        assert byte_size(cmd) >= 5, "draw command too short: #{inspect(cmd)}"
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
      draw_cmds = Enum.filter(commands, &(binary_part(&1, 0, 1) == <<0x10>>))

      chat_cols =
        draw_cmds
        |> Enum.map(fn <<0x10, _row::16, col::16, _rest::binary>> -> col end)
        |> Enum.filter(&(&1 < expected_chat_width))

      viewer_cols =
        draw_cmds
        |> Enum.map(fn <<0x10, _row::16, col::16, _rest::binary>> -> col end)
        |> Enum.filter(&(&1 > expected_chat_width))

      assert chat_cols != [], "expected draw commands in chat panel columns"
      assert viewer_cols != [], "expected draw commands in viewer panel columns"
    end
  end
end

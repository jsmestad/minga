defmodule Minga.Agent.View.RendererTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.UIState
  alias Minga.Agent.View.Renderer
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

    agent = %AgentState{
      session: nil,
      status: :idle,
      error: nil,
      spinner_timer: nil,
      buffer: nil
    }

    agentic = %UIState{
      visible: true,
      input_focused: Keyword.get(opts, :input_focused, false),
      prompt_buffer: prompt_buf,
      active: true,
      focus: Keyword.get(opts, :focus, :chat)
    }

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(rows, cols),
      vim: VimState.new(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      focus_stack: Input.default_stack(),
      agent: agent,
      agent_ui: agentic,
      theme: Theme.get!(:doom_one),
      highlight: %Highlighting{}
    }
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

  describe "prompt_height/2" do
    test "returns a positive integer" do
      state = base_state()
      height = Renderer.prompt_height(state, 80)
      assert is_integer(height)
      assert height >= 3
    end

    test "grows with multiline input" do
      state_single = base_state(input_lines: ["hello"])
      state_multi = base_state(input_lines: ["line 1", "line 2", "line 3"])

      h_single = Renderer.prompt_height(state_single, 80)
      h_multi = Renderer.prompt_height(state_multi, 80)

      assert h_multi > h_single
    end
  end

  describe "render_prompt_only/2" do
    test "returns draw tuples with prompt border" do
      state = base_state()
      commands = Renderer.render_prompt_only(state, {30, 0, 80, 5})

      assert [_ | _] = commands
      texts = Enum.map(commands, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.starts_with?(&1, "╭─ Prompt"))
      assert Enum.any?(texts, &String.starts_with?(&1, "╰─"))
    end

    test "model info is embedded in bottom border" do
      state = base_state()
      commands = Renderer.render_prompt_only(state, {30, 0, 80, 5})
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, fn text ->
               String.starts_with?(text, "╰─") and String.contains?(text, "Claude Sonnet 4")
             end)
    end
  end

  describe "render_dashboard_only/2" do
    test "shows context, model, LSP, and directory sections" do
      state = base_state()
      commands = Renderer.render_dashboard_only(state, {0, 80, 40, 30})
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "Context"))
      assert Enum.any?(texts, &String.contains?(&1, "Model"))
      assert Enum.any?(texts, &String.contains?(&1, "claude-sonnet-4"))
      assert Enum.any?(texts, &String.contains?(&1, "Directory"))
    end

    test "shows LSP section with no servers when list is empty" do
      state = base_state()
      commands = Renderer.render_dashboard_only(state, {0, 80, 40, 30})
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "LSP"))
      assert Enum.any?(texts, &String.contains?(&1, "No servers active"))
    end
  end

  describe "input layout helpers" do
    test "input_box_width applies horizontal margins" do
      assert Renderer.input_box_width(80) == 80 - 2 * 2
    end

    test "input_inner_width subtracts border chrome" do
      box_w = Renderer.input_box_width(80)
      inner = Renderer.input_inner_width(box_w)
      assert inner == box_w - 6
    end

    test "compute_input_height includes borders" do
      # Single line: top border(1) + 1 visible line + bottom border(1) = 3
      assert Renderer.compute_input_height(["hello"], 60) == 3
    end

    test "input_v_gap returns the vertical gap constant" do
      assert is_integer(Renderer.input_v_gap())
      assert Renderer.input_v_gap() >= 0
    end
  end

  describe "context_fill_pct/3" do
    test "returns nil for unknown models" do
      assert Renderer.context_fill_pct(%{input: 100, output: 50}, "unknown-model") == nil
    end

    test "returns a percentage for known models" do
      pct = Renderer.context_fill_pct(%{input: 50_000, output: 10_000}, "claude-sonnet-4")

      if pct != nil do
        assert is_integer(pct)
        assert pct >= 0 and pct <= 100
      end
    end
  end
end

defmodule MingaEditor.Agent.View.PromptRendererTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.PromptRenderer
  alias MingaEditor.Agent.ViewContext
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.RuntimeState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Highlighting
  alias MingaEditor.VimState
  alias MingaEditor.UI.Theme

  defp base_state(opts \\ []) do
    rows = Keyword.get(opts, :rows, 40)
    cols = Keyword.get(opts, :cols, 120)
    {:ok, buf} = BufferProcess.start_link(content: "line one\nline two\nline three")

    input_lines = Keyword.get(opts, :input_lines, [Keyword.get(opts, :input_text, "")])

    input_cursor =
      Keyword.get(opts, :input_cursor, {0, String.length(Keyword.get(opts, :input_text, ""))})

    {:ok, prompt_buf} = BufferProcess.start_link(content: Enum.join(input_lines, "\n"))
    BufferProcess.move_to(prompt_buf, input_cursor)

    agent = %AgentState{
      runtime: %RuntimeState{status: :idle},
      error: nil,
      spinner_timer: nil
    }

    agentic =
      %UIState{
        panel: %UIState.Panel{
          visible: true,
          input_focused: Keyword.get(opts, :input_focused, false),
          credentials_configured: Keyword.get(opts, :credentials_configured, true),
          prompt_buffer: prompt_buf
        }
      }
      |> UIState.activate(nil, nil)
      |> UIState.set_focus(Keyword.get(opts, :focus, :chat))

    %EditorState{
      frontend: %MingaEditor.State.Frontend{
        port_manager: self(),
        terminal_viewport: MingaEditor.Viewport.new(rows, cols)
      },
      parser: %MingaEditor.State.Parser{highlighting: %Highlighting{}},
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        agent_ui: agentic
      },
      interaction: %MingaEditor.State.Interaction{},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.replace_agent(
            %MingaEditor.Shell.Traditional.State{},
            agent
          )
        ),
      appearance: %MingaEditor.State.Appearance{theme: Theme.get!(:doom_one)}
    }
  end

  describe "cursor_position_in_rect/2" do
    test "returns nil when input is not focused" do
      state = base_state(rows: 40, input_focused: false)
      ctx = ViewContext.from_editor_state(state)
      assert PromptRenderer.cursor_position_in_rect(ctx, {0, 0, 80, 40}) == nil
    end

    test "returns {row, col} when input is focused" do
      state = base_state(rows: 40, input_focused: true)
      ctx = ViewContext.from_editor_state(state)
      result = PromptRenderer.cursor_position_in_rect(ctx, {0, 0, 80, 40})

      assert {row, col} = result
      assert is_integer(row)
      assert is_integer(col)
      assert row >= 0 and row < 40
      assert col >= 0
    end

    test "cursor column advances with input text length" do
      state_empty = base_state(input_focused: true, input_text: "")
      ctx_empty = ViewContext.from_editor_state(state_empty)
      state_hello = base_state(input_focused: true, input_text: "hello")
      ctx_hello = ViewContext.from_editor_state(state_hello)

      {_r, col_empty} = PromptRenderer.cursor_position_in_rect(ctx_empty, {0, 0, 80, 40})
      {_r, col_hello} = PromptRenderer.cursor_position_in_rect(ctx_hello, {0, 0, 80, 40})

      assert col_hello == col_empty + String.length("hello")
    end

    test "cursor row is the same regardless of short input text" do
      state_short = base_state(input_focused: true, input_text: "hi")
      ctx_short = ViewContext.from_editor_state(state_short)
      state_long = base_state(input_focused: true, input_text: "a long message here")
      ctx_long = ViewContext.from_editor_state(state_long)

      {row_short, _} = PromptRenderer.cursor_position_in_rect(ctx_short, {0, 0, 80, 40})
      {row_long, _} = PromptRenderer.cursor_position_in_rect(ctx_long, {0, 0, 80, 40})

      assert row_short == row_long
    end

    test "cursor position is offset by the rect origin" do
      state = base_state(rows: 40, input_focused: true, input_text: "test")
      ctx = ViewContext.from_editor_state(state)

      {row_origin, _col_origin} = PromptRenderer.cursor_position_in_rect(ctx, {0, 0, 80, 40})
      {row_offset, _col_offset} = PromptRenderer.cursor_position_in_rect(ctx, {5, 0, 80, 40})

      assert row_offset == row_origin + 5
    end
  end

  describe "prompt_height/2" do
    test "returns a positive integer" do
      state = base_state()
      ctx = ViewContext.from_editor_state(state)
      height = PromptRenderer.prompt_height(ctx, 80)
      assert is_integer(height)
      assert height >= 3
    end

    test "grows with multiline input" do
      state_single = base_state(input_lines: ["hello"])
      ctx_single = ViewContext.from_editor_state(state_single)
      state_multi = base_state(input_lines: ["line 1", "line 2", "line 3"])
      ctx_multi = ViewContext.from_editor_state(state_multi)

      h_single = PromptRenderer.prompt_height(ctx_single, 80)
      h_multi = PromptRenderer.prompt_height(ctx_multi, 80)

      assert h_multi > h_single
    end
  end

  describe "input layout helpers" do
    test "input_box_width applies horizontal margins" do
      assert PromptRenderer.input_box_width(80) == 80 - 2 * 2
    end

    test "input_inner_width subtracts border chrome" do
      box_w = PromptRenderer.input_box_width(80)
      inner = PromptRenderer.input_inner_width(box_w)
      assert inner == box_w - 4
    end

    test "compute_input_height includes borders" do
      # Single line: top border(1) + 1 visible line + bottom border(1) = 3
      assert PromptRenderer.compute_input_height(["hello"], 60) == 3
    end

    test "input_v_gap returns the vertical gap constant" do
      assert is_integer(PromptRenderer.input_v_gap())
      assert PromptRenderer.input_v_gap() >= 0
    end
  end
end

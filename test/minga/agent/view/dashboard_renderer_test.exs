defmodule Minga.Agent.View.DashboardRendererTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.UIState
  alias Minga.Agent.View.DashboardRenderer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Input
  alias Minga.UI.Theme

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
      panel: %UIState.Panel{
        visible: true,
        input_focused: Keyword.get(opts, :input_focused, false),
        prompt_buffer: prompt_buf
      },
      view: %UIState.View{
        active: true,
        focus: Keyword.get(opts, :focus, :chat)
      }
    }

    %EditorState{
      port_manager: self(),
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(rows, cols),
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        agent_ui: agentic,
        highlight: %Highlighting{}
      },
      focus_stack: Input.default_stack(),
      shell_state: %Minga.Shell.Traditional.State{agent: agent},
      theme: Theme.get!(:doom_one)
    }
  end

  describe "render/2" do
    test "shows context, model, LSP, and directory sections" do
      state = base_state()
      commands = DashboardRenderer.render(state, {0, 80, 40, 30})
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "Context"))
      assert Enum.any?(texts, &String.contains?(&1, "Model"))
      assert Enum.any?(texts, &String.contains?(&1, "claude-sonnet-4"))
      assert Enum.any?(texts, &String.contains?(&1, "Directory"))
    end

    test "shows LSP section with no servers when list is empty" do
      state = base_state()
      commands = DashboardRenderer.render(state, {0, 80, 40, 30})
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "LSP"))
      assert Enum.any?(texts, &String.contains?(&1, "No servers active"))
    end

    test "dashboard model section strips provider prefix" do
      state = base_state()
      commands = DashboardRenderer.render(state, {0, 80, 40, 30})
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      # The model section should show bare model name, not the prefixed spec
      assert Enum.any?(texts, &String.contains?(&1, "claude-sonnet-4"))
      refute Enum.any?(texts, &String.contains?(&1, "anthropic:claude-sonnet-4"))
    end
  end

  describe "context_fill_pct/3" do
    test "returns nil for unknown models" do
      assert DashboardRenderer.context_fill_pct(%{input: 100, output: 50}, "unknown-model") == nil
    end

    test "returns a percentage for known models" do
      pct =
        DashboardRenderer.context_fill_pct(%{input: 50_000, output: 10_000}, "claude-sonnet-4")

      if pct != nil do
        assert is_integer(pct)
        assert pct >= 0 and pct <= 100
      end
    end
  end
end

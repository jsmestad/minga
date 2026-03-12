defmodule Minga.Editor.Commands.AgentCodeBlockTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Surface.AgentView.State, as: AgentViewState

  defp base_state do
    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Minga.Mode.initial_state(),
      buffers: %Buffers{},
      surface_module: Minga.Surface.AgentView,
      surface_state: %AgentViewState{
        agent: %AgentState{},
        agentic: %ViewState{},
        context: nil
      }
    }
  end

  describe "open_code_block/3" do
    test "creates a buffer with the code block content" do
      state = base_state()
      content = "defmodule Foo do\n  def bar, do: :ok\nend"
      new_state = AgentCommands.open_code_block(state, "elixir", content)

      buf = new_state.buffers.active
      assert is_pid(buf)
      assert BufferServer.content(buf) == content
    end

    test "sets buffer name based on language" do
      state = base_state()
      new_state = AgentCommands.open_code_block(state, "python", "print('hi')")

      buf = new_state.buffers.active
      name = BufferServer.buffer_name(buf)
      assert name == "*Agent: python*"
    end

    test "sets buffer name to text when language is empty" do
      state = base_state()
      new_state = AgentCommands.open_code_block(state, "", "some plain text")

      buf = new_state.buffers.active
      name = BufferServer.buffer_name(buf)
      assert name == "*Agent: text*"
    end

    test "sets filetype based on language tag" do
      state = base_state()
      new_state = AgentCommands.open_code_block(state, "elixir", "IO.puts(:ok)")

      buf = new_state.buffers.active
      assert BufferServer.filetype(buf) == :elixir
    end

    test "handles unknown language tags gracefully" do
      state = base_state()
      new_state = AgentCommands.open_code_block(state, "brainfuck", "+++[>+<-]")

      buf = new_state.buffers.active
      assert is_pid(buf)
      assert BufferServer.content(buf) == "+++[>+<-]"
    end

    test "maps common aliases (js -> javascript, py -> python)" do
      state = base_state()

      js_state = AgentCommands.open_code_block(state, "js", "console.log('hi')")
      assert BufferServer.filetype(js_state.buffers.active) == :javascript

      py_state = AgentCommands.open_code_block(state, "py", "print('hi')")
      assert BufferServer.filetype(py_state.buffers.active) == :python

      sh_state = AgentCommands.open_code_block(state, "bash", "echo hi")
      assert BufferServer.filetype(sh_state.buffers.active) == :bash
    end
  end
end

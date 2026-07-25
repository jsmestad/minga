defmodule MingaEditor.Commands.AgentCodeBlockTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.Manager
  alias MingaEditor.Agent.UIState
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.VimState

  defp base_state(opts \\ []) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{},
        agent_ui: %UIState{}
      },
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.replace_agent(
            %MingaEditor.Shell.Traditional.State{},
            %AgentState{}
          )
        ),
      parser:
        MingaEditor.State.Parser.new(Keyword.get(opts, :parser_manager, Minga.Parser.Manager))
    }
  end

  describe "open_code_block/3" do
    test "creates a buffer with the code block content" do
      state = base_state()
      content = "defmodule Foo do\n  def bar, do: :ok\nend"
      new_state = AgentCommands.open_code_block(state, "elixir", content)

      buf = new_state.workspace.buffers.active
      assert is_pid(buf)
      assert BufferProcess.content(buf) == content
    end

    test "sets buffer name based on language" do
      state = base_state()
      new_state = AgentCommands.open_code_block(state, "python", "print('hi')")

      buf = new_state.workspace.buffers.active
      name = BufferProcess.buffer_name(buf)
      assert name == "*Agent: python*"
    end

    test "sets buffer name to text when language is empty" do
      state = base_state()
      new_state = AgentCommands.open_code_block(state, "", "some plain text")

      buf = new_state.workspace.buffers.active
      name = BufferProcess.buffer_name(buf)
      assert name == "*Agent: text*"
    end

    test "sets filetype based on language tag" do
      state = base_state()
      new_state = AgentCommands.open_code_block(state, "elixir", "IO.puts(:ok)")

      buf = new_state.workspace.buffers.active
      assert BufferProcess.filetype(buf) == :elixir
    end

    test "supported language initializes active parser presentation", %{test: test} do
      manager =
        start_supervised!(
          {Manager,
           name: Module.concat(__MODULE__, "Parser#{test}"), parser_path: "/missing/minga-parser"}
        )

      content = "defmodule Foo do\n  def bar, do: :ok\nend"

      new_state =
        AgentCommands.open_code_block(base_state(parser_manager: manager), "elixir", content)

      buf = new_state.workspace.buffers.active

      assert BufferProcess.content(buf) == content
      assert BufferProcess.filetype(buf) == :elixir
      assert is_integer(Manager.buffer_id(buf, manager))
      assert Map.has_key?(new_state.parser.highlighting.highlights, buf)
    end

    test "handles unknown language tags without parser registration", %{test: test} do
      manager =
        start_supervised!(
          {Manager,
           name: Module.concat(__MODULE__, "Parser#{test}"), parser_path: "/missing/minga-parser"}
        )

      new_state =
        AgentCommands.open_code_block(
          base_state(parser_manager: manager),
          "brainfuck",
          "+++[>+<-]"
        )

      buf = new_state.workspace.buffers.active
      assert is_pid(buf)
      assert BufferProcess.content(buf) == "+++[>+<-]"
      assert Manager.buffer_id(buf, manager) == nil
    end

    test "maps common aliases (js -> javascript, py -> python)" do
      state = base_state()

      js_state = AgentCommands.open_code_block(state, "js", "console.log('hi')")
      assert BufferProcess.filetype(js_state.workspace.buffers.active) == :javascript

      py_state = AgentCommands.open_code_block(state, "py", "print('hi')")
      assert BufferProcess.filetype(py_state.workspace.buffers.active) == :python

      sh_state = AgentCommands.open_code_block(state, "bash", "echo hi")
      assert BufferProcess.filetype(sh_state.workspace.buffers.active) == :bash
    end
  end
end

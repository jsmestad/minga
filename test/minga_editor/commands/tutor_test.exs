defmodule MingaEditor.Commands.TutorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Command.Parser
  alias Minga.Config.Options
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias MingaEditor.Commands.Tutor
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport

  defp build_state do
    {:ok, buf} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {BufferProcess, content: "hello", buffer_name: "test.txt"}
      )

    {:ok, keymap} = ActiveKeymap.start_link(name: nil)
    {:ok, options} = Minga.Config.Options.start_link(name: nil)

    %EditorState{
      port_manager: nil,
      keymap_server: keymap,
      options_server: options,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]}
      }
    }
  end

  describe "execute/2" do
    test "creates a *Tutor* buffer with tutorial content" do
      state = build_state()

      assert {:ok, false} =
               Options.set_for_filetype(state.options_server, :text, :autopair_block, false)

      result = Tutor.execute(state, :tutor)

      tutor_buf = result.workspace.buffers.active
      assert BufferProcess.buffer_name(tutor_buf) == "*Tutor*"
      assert BufferProcess.get_option(tutor_buf, :autopair_block) == false

      content = BufferProcess.content(tutor_buf)
      assert content =~ "M i n g a   T u t o r"
      assert content =~ "Lesson 1"
      assert content =~ "MOVING THE CURSOR"
    end

    test "tutor buffer is writable" do
      state = build_state()
      result = Tutor.execute(state, :tutor)

      tutor_buf = result.workspace.buffers.active
      refute BufferProcess.read_only?(tutor_buf)
    end

    test "tutor buffer uses :nofile type" do
      state = build_state()
      result = Tutor.execute(state, :tutor)

      tutor_buf = result.workspace.buffers.active
      assert BufferProcess.buffer_type(tutor_buf) == :nofile
    end

    test "tutor buffer is added to buffer list" do
      state = build_state()
      result = Tutor.execute(state, :tutor)

      tutor_buf = result.workspace.buffers.active
      assert tutor_buf in result.workspace.buffers.list
    end

    test "re-running :Tutor resets content to a fresh copy" do
      state = build_state()
      result = Tutor.execute(state, :tutor)
      tutor_buf = result.workspace.buffers.active

      BufferProcess.insert_text(tutor_buf, "MODIFIED ")
      assert BufferProcess.content(tutor_buf) =~ "MODIFIED"

      result2 = Tutor.execute(result, :tutor)
      assert result2.workspace.buffers.active == tutor_buf
      refute BufferProcess.content(tutor_buf) =~ "MODIFIED"
      assert BufferProcess.content(tutor_buf) =~ "M i n g a   T u t o r"
    end

    test "creates a new buffer when the previous tutor buffer process died" do
      state = build_state()
      result = Tutor.execute(state, :tutor)
      old_tutor = result.workspace.buffers.active

      GenServer.stop(old_tutor)
      refute Process.alive?(old_tutor)

      result2 = Tutor.execute(result, :tutor)
      new_tutor = result2.workspace.buffers.active

      assert Process.alive?(new_tutor)
      assert new_tutor != old_tutor
      assert BufferProcess.buffer_name(new_tutor) == "*Tutor*"
    end

    test "sets a status message" do
      state = build_state()
      result = Tutor.execute(state, :tutor)

      assert result.shell_state.status_msg =~ "Tutorial"
    end

    test "includes Minga-specific lessons" do
      state = build_state()
      result = Tutor.execute(state, :tutor)

      content = BufferProcess.content(result.workspace.buffers.active)
      assert content =~ "LEADER KEY"
      assert content =~ "SPC f f"
      assert content =~ "AGENT PANEL"
      assert content =~ "SPC a a"
    end
  end

  describe "ex-command parsing" do
    test ":Tutor parses to {:tutor, []}" do
      assert {:tutor, []} = Parser.parse("Tutor")
    end

    test ":tutor (lowercase) parses to {:tutor, []}" do
      assert {:tutor, []} = Parser.parse("tutor")
    end
  end
end

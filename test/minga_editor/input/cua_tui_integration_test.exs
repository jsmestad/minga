defmodule MingaEditor.Input.CUATUIIntegrationTest do
  @moduledoc """
  Integration tests for CUA mode on the TUI input path.
  """

  # async: false because these tests pin global startup_view so TUI starts in editor view.
  use Minga.Test.EditorCase, async: false

  import ExUnit.CaptureLog

  alias Minga.Config.Options
  alias Minga.Keymap.Bindings
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Registers
  alias MingaEditor.State.WhichKey

  @ctrl 0x02
  @enter 13
  @space 32

  setup do
    previous_startup_view = Options.get(:startup_view)
    Options.set(:startup_view, :editor)

    on_exit(fn -> Options.set(:startup_view, previous_startup_view) end)

    :ok
  end

  describe "CUA TUI editor input" do
    test "printable characters self-insert" do
      ctx = start_editor("", editing_model: :cua, backend: :tui)

      send_key_sync(ctx, ?h)
      send_key_sync(ctx, ?i)

      assert buffer_content(ctx) == "hi"
    end

    test "Ctrl fallbacks cover undo and redo" do
      ctx = start_editor("", editing_model: :cua, backend: :tui)

      send_key_sync(ctx, ?a)
      assert buffer_content(ctx) == "a"

      send_key_sync(ctx, ?z, @ctrl)
      assert buffer_content(ctx) == ""

      send_key_sync(ctx, ?y, @ctrl)
      assert buffer_content(ctx) == "a"
    end

    test "Ctrl+A selects all and Ctrl+C copies the selection" do
      ctx = start_editor("alpha", editing_model: :cua, backend: :tui)

      send_key_sync(ctx, ?a, @ctrl)
      assert editor_mode(ctx) == :visual

      send_key_sync(ctx, ?c, @ctrl)
      state = editor_state(ctx)

      assert {"alpha\n", :linewise} = Registers.get(MingaEditor.Editing.registers(state), "")
      assert buffer_content(ctx) == "alpha"
    end

    test "Ctrl+S routes through the global save lifecycle" do
      uniq = System.unique_integer([:positive])
      path = Path.join(System.tmp_dir!(), "minga-cua-save-#{uniq}.txt")
      File.write!(path, "alpha\n")
      on_exit(fn -> File.rm(path) end)

      ctx = start_editor("alpha\n", file_path: path, editing_model: :cua, backend: :tui)
      Minga.Events.subscribe(:buffer_saved, ctx.events_registry)
      buffer = ctx.buffer

      send_key_sync(ctx, ?!)
      send_key_sync(ctx, ?s, @ctrl)

      assert_receive {:minga_event, :buffer_saved,
                      %Minga.Events.BufferEvent{buffer: ^buffer, path: ^path}}

      assert File.read!(path) == "!alpha\n"
      assert buffer_content(ctx) == "!alpha\n"
      assert BufferProcess.dirty?(buffer) == false
    end

    test "Ctrl+C with no visual selection interrupts and clears editor status" do
      ctx = start_editor("alpha", editing_model: :cua, backend: :tui)

      :sys.replace_state(ctx.editor, fn state ->
        state
        |> EditorState.set_status("dirty")
        |> EditorState.update_shell_state(&ShellState.set_space_leader_pending(&1, true))
        |> EditorState.set_whichkey(%WhichKey{
          node: Bindings.new(),
          show: true,
          prefix_keys: ["SPC"]
        })
        |> EditorState.set_registers(
          Registers.put(MingaEditor.Editing.registers(state), "", "existing")
        )
      end)

      send_key_sync(ctx, ?c, @ctrl)
      state = editor_state(ctx)

      assert EditorState.status_msg(state) == nil
      assert state.shell_state.space_leader_pending == false
      assert EditorState.whichkey(state) == %WhichKey{}
      assert Registers.get(MingaEditor.Editing.registers(state), "") == {"existing", :charwise}
      assert buffer_content(ctx) == "alpha"
    end
  end

  describe "CUA TUI agent prompt" do
    test "printable characters self-insert in the focused agent prompt" do
      ctx = start_editor("", editing_model: :cua, backend: :tui)
      focus_agent_prompt(ctx)

      send_key_sync(ctx, ?x)
      state = editor_state(ctx)

      assert UIState.input_text(AgentAccess.panel(state)) == "x"
      assert buffer_content(ctx) == ""
    end

    test "Enter submits the focused prompt instead of refocusing it" do
      ctx = start_editor("", editing_model: :cua, backend: :tui)
      focus_agent_prompt(ctx, "hello agent")

      send_key_sync(ctx, @enter)
      state = editor_state(ctx)

      assert AgentAccess.input_focused?(state)
      assert UIState.input_text(AgentAccess.panel(state)) == "hello agent"
      assert EditorState.status_msg(state) =~ "No agent session"
    end
  end

  describe "CUA TUI SPC leader" do
    test "SPC then a leader key enters leader mode and retracts the inserted space" do
      ctx = start_editor("", editing_model: :cua, backend: :tui)

      send_key_sync(ctx, @space)
      assert editor_state(ctx).shell_state.space_leader_pending == true

      send_key_sync(ctx, ?f)
      state = editor_state(ctx)

      assert state.shell_state.whichkey.node != nil
      assert state.shell_state.space_leader_pending == false
      assert buffer_content(ctx) == ""
    end
  end

  describe "CUA TUI startup defaults" do
    test "default editing model remains vim" do
      assert Minga.Config.get(:editing_model) == :vim
    end

    test "CUA on TUI logs a startup warning" do
      log = capture_log(fn -> start_editor("", editing_model: :cua, backend: :tui) end)

      assert log =~ "CUA mode is not fully supported on TUI"
    end
  end

  defp focus_agent_prompt(ctx, text \\ "") do
    :sys.replace_state(ctx.editor, fn state ->
      state
      |> EditorState.set_keymap_scope(:agent)
      |> AgentAccess.update_agent_ui(fn ui ->
        ui
        |> UIState.ensure_prompt_buffer()
        |> UIState.set_input_focused(true)
        |> UIState.set_prompt_text(text)
      end)
    end)

    :sys.get_state(ctx.editor)
  end
end

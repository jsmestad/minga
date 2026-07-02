defmodule MingaEditor.LaunchpadIntegrationTest do
  @moduledoc """
  Entry/exit, input routing, and activation behavior for the zero-buffers
  launchpad (#2689).
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Commands.Launchpad, as: LaunchpadCommands
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Launchpad

  @sync_timeout 30_000

  describe "entering the launchpad" do
    test "killing the last buffer enters the launchpad with zero buffers", %{tmp_dir: tmp} do
      {state, _buffer} = command_state("only buffer", tmp)

      state = BufferManagement.execute(state, :kill_buffer)

      assert state.workspace.buffers.active == nil
      assert state.workspace.buffers.list == []
      assert %Launchpad{} = state.workspace.launchpad
      assert EditorState.active_window_struct(state).content == {:empty, :semantic}
      assert EditorState.tab_bar(state).tabs == []
    end

    test "killing one of two buffers does not enter the launchpad", %{tmp_dir: tmp} do
      {state, _buffer} = command_state("first", tmp)
      {:ok, second} = BufferProcess.start_link(content: "second")
      state = EditorState.add_buffer(state, second, context: :open)

      state = BufferManagement.execute(state, :kill_buffer)

      assert is_pid(state.workspace.buffers.active)
      assert state.workspace.launchpad == nil
    end
  end

  describe "activation" do
    test "materialize_and_insert creates an Untitled buffer in insert mode", %{tmp_dir: tmp} do
      state = empty_state(tmp)

      state = LaunchpadCommands.materialize_and_insert(state)

      active = state.workspace.buffers.active
      assert is_pid(active)
      assert BufferProcess.buffer_name(active) == "Untitled-1"
      assert Minga.Editing.mode(state) == :insert
      assert state.workspace.launchpad == nil
      assert EditorState.active_window_struct(state).content == {:buffer, active}
    end

    test "activating a recent item opens the file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "recent.ex")
      File.write!(path, "defmodule Recent do\nend\n")

      state = empty_state(tmp, recents: [path])

      state = LaunchpadCommands.activate(state, "recent-1")

      active = state.workspace.buffers.active
      assert is_pid(active)
      assert BufferProcess.file_path(active) == path
      assert state.workspace.launchpad == nil
    end

    test "activating an unknown id is a no-op", %{tmp_dir: tmp} do
      state = empty_state(tmp)

      assert LaunchpadCommands.activate(state, "bogus") == state
    end

    test "resume reopens the previous session's files", %{tmp_dir: tmp} do
      session_dir = Path.join(tmp, "sessions")
      path = Path.join(tmp, "restored.ex")
      File.write!(path, "defmodule Restored do\nend\n")

      # Snapshot a session holding the file, then start over with no buffers.
      {file_state, _buffer} = command_state_for_file(path, tmp)
      snapshot = Minga.Session.snapshot(file_state)
      assert :ok = Minga.Session.save(snapshot, session_dir: session_dir)

      state = empty_state(tmp, session_dir: session_dir)

      state = LaunchpadCommands.activate(state, "resume")

      paths =
        state.workspace.buffers.list
        |> Enum.map(&BufferProcess.file_path/1)

      assert path in paths
      assert state.workspace.launchpad == nil
    end
  end

  describe "key routing through the focus stack" do
    test "j/k move focus, gg/G jump, i materializes, q passes through", %{tmp_dir: tmp} do
      editor = start_empty_editor(tmp)

      # First run: the Get started hero holds the initial focus.
      state = send_key(editor, ?j)
      lp = state.workspace.launchpad
      assert lp.focused_id == "action-find-file"

      state = send_key(editor, ?k)
      assert state.workspace.launchpad.focused_id == "action-tutor"

      state = send_key(editor, ?G)
      assert state.workspace.launchpad.focused_id == "action-palette"

      send_key(editor, ?g)
      state = send_key(editor, ?g)
      assert state.workspace.launchpad.focused_id == "action-tutor"

      # `q` is not claimed: it falls through to normal mode (a no-op there).
      state = send_key(editor, ?q)
      assert state.workspace.launchpad != nil

      # `i` materializes an Untitled buffer in insert mode.
      state = send_key(editor, ?i)
      assert is_pid(state.workspace.buffers.active)
      assert Minga.Editing.mode(state) == :insert
      assert state.workspace.launchpad == nil
    end

    test "Enter on the first-run hero opens the tutorial", %{tmp_dir: tmp} do
      editor = start_empty_editor(tmp)

      # The Get started hero card carries the RET chip and the focus, so
      # Enter-on-launch must honor it: the tutorial opens and the
      # launchpad exits.
      state = send_key(editor, 13)

      active = state.workspace.buffers.active
      assert is_pid(active)
      assert Minga.Buffer.Process.buffer_name(active) == "*Tutor*"
      assert state.workspace.launchpad == nil
    end

    test "Enter activates the focused row after moving focus", %{tmp_dir: tmp} do
      editor = start_empty_editor(tmp)

      # j moves to open-file; Enter opens the file picker without
      # leaving the empty state.
      send_key(editor, ?j)
      state = send_key(editor, 13)

      assert state.shell_state.modal != :none
      assert state.workspace.launchpad != nil
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp command_state(content, tmp) do
    {:ok, buffer} = BufferProcess.start_link(content: content)
    {command_state_for_buffer(buffer, tmp), buffer}
  end

  defp command_state_for_file(path, tmp) do
    {:ok, buffer} = BufferProcess.start_link(file_path: path)
    {command_state_for_buffer(buffer, tmp), buffer}
  end

  defp command_state_for_buffer(buffer, tmp) do
    {:ok, options} = Options.start_link(name: nil)

    Startup.build_initial_state(
      port_manager: nil,
      options_server: options,
      buffer: buffer,
      width: 60,
      height: 20,
      editing_model: :vim,
      session_dir: Path.join(tmp, "empty-sessions")
    )
  end

  defp empty_state(tmp, opts \\ []) do
    {:ok, options} = Options.start_link(name: nil)

    state =
      Startup.build_initial_state(
        port_manager: nil,
        options_server: options,
        buffer: nil,
        width: 60,
        height: 20,
        editing_model: :vim,
        session_dir: Keyword.get(opts, :session_dir, Path.join(tmp, "no-sessions"))
      )

    case Keyword.fetch(opts, :recents) do
      {:ok, recents} ->
        lp = Launchpad.new(session_file_count: 0, recents: recents)
        EditorState.update_workspace(state, &MingaEditor.Session.State.set_launchpad(&1, lp))

      :error ->
        maybe_reload_launchpad(state, opts)
    end
  end

  # build_initial_state snapshots the launchpad from :session_dir; when a
  # session fixture was written after boot options were chosen, rebuild it.
  defp maybe_reload_launchpad(state, opts) do
    case Keyword.fetch(opts, :session_dir) do
      {:ok, dir} ->
        lp = Launchpad.new(session_dir: dir)
        EditorState.update_workspace(state, &MingaEditor.Session.State.set_launchpad(&1, lp))

      :error ->
        state
    end
  end

  defp start_empty_editor(tmp) do
    {:ok, options} = Options.start_link(name: nil)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"launchpad_editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        options_server: options,
        buffer: nil,
        width: 60,
        height: 20,
        editing_model: :vim,
        session_dir: Path.join(tmp, "editor-sessions")
      )

    # The boot-time launchpad snapshots the global Project recents, which
    # vary across machines and concurrent tests; pin a deterministic one.
    deterministic = Launchpad.new(session_file_count: 0, recents: [])

    :sys.replace_state(editor, fn state ->
      EditorState.update_workspace(
        state,
        &MingaEditor.Session.State.set_launchpad(&1, deterministic)
      )
    end)

    editor
  end

  defp send_key(editor, codepoint) do
    send(editor, {:minga_input, {:key_press, codepoint, 0}})
    :sys.get_state(editor, @sync_timeout)
  end
end

defmodule MingaEditor.Commands.DiredMutationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Dired
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Commands.Dired, as: DiredCommands
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Dired, as: DiredState
  alias MingaEditor.Viewport

  @moduletag :tmp_dir

  test "cancel preserves files and confirmation applies create, rename, delete, and mkdir", %{
    tmp_dir: dir
  } do
    old_path = Path.join(dir, "old.txt")
    deleted_path = Path.join(dir, "deleted.txt")
    renamed_path = Path.join(dir, "renamed.txt")
    created_path = Path.join(dir, "created.txt")
    created_dir = Path.join(dir, "created-dir")
    File.write!(old_path, "old")

    {:ok, listing} = Dired.read_directory(dir)
    {:ok, buffer} = start_supervised({BufferProcess, content: Dired.format_listing(listing)})
    state = editor_state(buffer, DiredState.activate(%DiredState{}, listing, buffer))

    BufferProcess.replace_content(buffer, "renamed.txt")
    prompted = DiredCommands.execute(state, :dired_apply_changes)

    assert prompted.workspace.dired.confirming?
    assert prompted.workspace.dired.pending_ops == [{:rename, old_path, renamed_path}]

    cancelled = DiredCommands.execute(prompted, :dired_cancel_apply)

    refute cancelled.workspace.dired.confirming?
    assert File.exists?(old_path)
    refute File.exists?(renamed_path)

    File.write!(deleted_path, "deleted")

    operations = [
      {:rename, old_path, renamed_path},
      {:delete, deleted_path},
      {:create, created_path},
      {:mkdir, created_dir}
    ]

    confirming =
      then(cancelled, fn state ->
        %{
          state
          | workspace:
              then(
                state.workspace,
                &MingaEditor.Session.State.set_dired(
                  &1,
                  DiredState.enter_confirmation(cancelled.workspace.dired, operations)
                )
              )
        }
      end)

    applied = DiredCommands.execute(confirming, :dired_confirm_apply)

    refute applied.workspace.dired.confirming?
    refute File.exists?(old_path)
    refute File.exists?(deleted_path)
    assert File.read!(renamed_path) == "old"
    assert File.exists?(created_path)
    assert File.dir?(created_dir)
  end

  test "Dired save and close commands target the stored backing buffer exactly", %{tmp_dir: dir} do
    old_path = Path.join(dir, "old.txt")
    renamed_path = Path.join(dir, "renamed.txt")
    File.write!(old_path, "old")
    {listing, dired_buffer} = dired_fixture(dir)
    dired = DiredState.activate(%DiredState{}, listing, dired_buffer)
    BufferProcess.replace_content(dired_buffer, "renamed.txt")
    prompted = BufferManagement.execute(editor_state(dired_buffer, dired), :save)
    assert prompted.workspace.dired.confirming?
    assert prompted.workspace.dired.pending_ops == [{:rename, old_path, renamed_path}]

    for command <- [:save, :force_save] do
      command_dir = Path.join(dir, Atom.to_string(command))
      File.mkdir_p!(command_dir)
      File.write!(Path.join(command_dir, "old.txt"), "old")
      file_path = Path.join(command_dir, "#{command}.txt")
      File.write!(file_path, "before")
      {inactive_listing, inactive_dired_buffer} = dired_fixture(command_dir)
      file_buffer = start_buffer("before", file_path: file_path)
      inactive_dired = DiredState.activate(%DiredState{}, inactive_listing, inactive_dired_buffer)
      BufferProcess.replace_content(inactive_dired_buffer, "renamed.txt")
      BufferProcess.replace_content(file_buffer, "after")
      saved = BufferManagement.execute(editor_state(file_buffer, inactive_dired), command)
      assert File.read!(file_path) == "after"
      refute saved.workspace.dired.confirming?
      assert saved.workspace.dired.pending_ops == []
    end

    [earlier_buffer, active_buffer, later_buffer] =
      Enum.map(["earlier", "active", "later"], &start_buffer/1)

    editor_ref = Process.monitor(dired_buffer)
    test_ref = Process.monitor(dired_buffer)
    active_ref = Process.monitor(active_buffer)
    buffers = [earlier_buffer, dired_buffer, active_buffer, later_buffer]

    closed = close_dired(active_buffer, dired, buffers, 2, %{dired_buffer => editor_ref})

    assert_receive {:DOWN, ^test_ref, :process, ^dired_buffer, :normal}
    refute_receive {:DOWN, ^active_ref, :process, ^active_buffer, _}
    assert closed.workspace.buffers.active == active_buffer
    assert closed.workspace.buffers.active_index == 1
    assert closed.workspace.buffers.list == [earlier_buffer, active_buffer, later_buffer]
    assert_dired_clean(closed)
    refute Map.has_key?(closed.buffer_lifecycle.buffer_monitors, dired_buffer)
    {dead_listing, dead_buffer} = dired_fixture(Path.join(dir, "force_save"))
    dead_dired = DiredState.activate(%DiredState{}, dead_listing, dead_buffer)
    dead_ref = Process.monitor(dead_buffer)
    GenServer.stop(dead_buffer, :normal)
    assert_receive {:DOWN, ^dead_ref, :process, ^dead_buffer, :normal}

    dead_closed =
      close_dired(active_buffer, dead_dired, [dead_buffer, active_buffer], 1, %{
        dead_buffer => dead_ref
      })

    assert dead_closed.workspace.buffers.active == active_buffer
    refute dead_buffer in dead_closed.workspace.buffers.list
    assert_dired_clean(dead_closed)

    failing_buffer = spawn(fn -> receive do: (_message -> exit(:boom)) end)
    failing_dired = DiredState.activate(%DiredState{}, %Dired{directory: dir}, failing_buffer)

    failed = close_dired(active_buffer, failing_dired, [failing_buffer, active_buffer], 1, %{})

    assert failed.workspace.dired.buffer == failing_buffer
    assert failed.workspace.buffers.list == [failing_buffer, active_buffer]
  end

  defp dired_fixture(dir) do
    {:ok, listing} = Dired.read_directory(dir)
    {listing, start_buffer(Dired.format_listing(listing))}
  end

  defp start_buffer(content, opts \\ []) do
    start_supervised!(%{
      id: {:buffer, make_ref()},
      start: {BufferProcess, :start_link, [Keyword.merge([content: content], opts)]}
    })
  end

  defp editor_state(buffer, dired_state) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buffer, list: [buffer]},
        dired: dired_state
      }
    }
  end

  defp close_dired(active_buffer, dired_state, buffers, active_index, monitors) do
    state = editor_state(active_buffer, dired_state)

    %{
      state
      | buffer_lifecycle: %MingaEditor.State.BufferLifecycle{buffer_monitors: monitors},
        workspace: %SessionState{
          state.workspace
          | buffers: %Buffers{active: active_buffer, list: buffers, active_index: active_index},
            keymap_scope: :dired
        }
    }
    |> DiredCommands.execute(:dired_close)
  end

  defp assert_dired_clean(state) do
    refute state.workspace.dired.active?
    assert state.workspace.keymap_scope == :editor
  end
end

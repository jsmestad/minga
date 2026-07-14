defmodule MingaEditor.Commands.DiredMutationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Dired
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
end

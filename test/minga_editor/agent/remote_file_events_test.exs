defmodule MingaEditor.Agent.RemoteFileEventsTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer
  alias MingaEditor.Agent.Events
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Remote
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.RemoteFileConflictSource

  @moduletag :tmp_dir

  test "agent file_changed reloads a clean remote buffer", %{tmp_dir: tmp_dir} do
    ctx = start_editor("initial")
    path = Path.join(tmp_dir, "file.ex")
    File.write!(path, "before")
    {:ok, buffer} = Buffer.start_link(file_path: path, storage: {:remote, node(), path})

    state =
      ctx
      |> editor_state()
      |> EditorState.update_remote(&Remote.put_buffer(&1, "home", path, buffer))

    {state, effects} = Events.handle(state, {:file_changed, path, "before", "after"})

    assert Buffer.content(buffer) == "after"
    refute Buffer.dirty?(buffer)
    assert {:log_message, "Agent updated file.ex"} in effects
    assert %EditorState{} = state
  end

  test "agent file_changed keeps dirty remote buffer content and warns about conflict", %{
    tmp_dir: tmp_dir
  } do
    ctx = start_editor("initial")
    path = Path.join(tmp_dir, "file.ex")
    File.write!(path, "before")
    {:ok, buffer} = Buffer.start_link(file_path: path, storage: {:remote, node(), path})
    :ok = Buffer.insert_text(buffer, "local ")

    state =
      ctx
      |> editor_state()
      |> EditorState.update_remote(&Remote.put_buffer(&1, "home", path, buffer))

    {state, effects} = Events.handle(state, {:file_changed, path, "before", "after"})

    assert Buffer.content(buffer) == "local before"
    assert Buffer.dirty?(buffer)
    assert state.shell_state.status_msg =~ "Agent modified this file"
    assert {:log_warning, "Agent modified dirty remote file file.ex"} in effects
    assert {:picker, %{picker_ui: %{source: RemoteFileConflictSource}}} = state.shell_state.modal
  end

  test "remote conflict prompt reload action discards local edits", %{tmp_dir: tmp_dir} do
    ctx = start_editor("initial")
    path = Path.join(tmp_dir, "file.ex")
    File.write!(path, "before")
    {:ok, buffer} = Buffer.start_link(file_path: path, storage: {:remote, node(), path})
    :ok = Buffer.insert_text(buffer, "local ")

    item = %Item{
      id: {:remote_conflict, :reload, buffer, path, "after"},
      label: "Reload"
    }

    state = RemoteFileConflictSource.on_select(item, editor_state(ctx))

    assert Buffer.content(buffer) == "after"
    refute Buffer.dirty?(buffer)
    assert state.shell_state.status_msg == "Reloaded file.ex from remote"
  end

  test "remote conflict prompt keep action preserves local edits", %{tmp_dir: tmp_dir} do
    ctx = start_editor("initial")
    path = Path.join(tmp_dir, "file.ex")
    File.write!(path, "before")
    {:ok, buffer} = Buffer.start_link(file_path: path, storage: {:remote, node(), path})
    :ok = Buffer.insert_text(buffer, "local ")

    item = %Item{
      id: {:remote_conflict, :keep, buffer, path, "after"},
      label: "Keep editing"
    }

    state = RemoteFileConflictSource.on_select(item, editor_state(ctx))

    assert Buffer.content(buffer) == "local before"
    assert Buffer.dirty?(buffer)
    assert state.shell_state.status_msg =~ "Keeping local edits"
  end

  test "remote conflict prompt show diff action leaves content untouched", %{tmp_dir: tmp_dir} do
    ctx = start_editor("initial")
    path = Path.join(tmp_dir, "file.ex")
    File.write!(path, "before")
    {:ok, buffer} = Buffer.start_link(file_path: path, storage: {:remote, node(), path})
    :ok = Buffer.insert_text(buffer, "local ")

    item = %Item{
      id: {:remote_conflict, :show_diff, buffer, path, "after"},
      label: "Show diff"
    }

    state = RemoteFileConflictSource.on_select(item, editor_state(ctx))

    assert Buffer.content(buffer) == "local before"
    assert Buffer.dirty?(buffer)
    assert state.shell_state.status_msg == "Showing diff for file.ex"
  end
end

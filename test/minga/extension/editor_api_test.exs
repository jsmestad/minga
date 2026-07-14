defmodule MingaEditor.Extension.EditorAPITest do
  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.State, as: EditorState

  test "set_status/2 sets a transient status message" do
    state = base_state(content: "hello world")

    assert state
           |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("Test status message")
           |> MingaEditor.Shell.Traditional.NoticeWorkflow.message() ==
             "Test status message"
  end

  test "open_file/2 opens an existing file and makes its buffer active" do
    path = write_temp_file("extension_editor_api_test", "file content here")

    active =
      base_state(content: "original content") |> EditorAPI.open_file(path) |> active_buffer()

    assert is_pid(active)
    assert Minga.Buffer.file_path(active) == path
  end

  test "open_file/2 leaves valid state when the file does not exist" do
    state = base_state(content: "original content")
    assert %EditorState{} = EditorAPI.open_file(state, "/nonexistent/path/to/file.ex")
  end

  test "navigate_to/4 opens a file and moves its cursor" do
    path = write_temp_file("editor_api_nav_test", "line one\nline two\nline three\nline four\n")

    active =
      base_state(content: "original")
      |> EditorAPI.navigate_to(path, 2, 0)
      |> active_buffer()

    assert Minga.Buffer.cursor(active) == {2, 0}
  end

  test "navigate_to/4 moves within an already active file" do
    path =
      write_temp_file("editor_api_nav_active_test", "line one\nline two\nline three\nline four\n")

    active =
      base_state(content: "original")
      |> EditorAPI.open_file(path)
      |> EditorAPI.navigate_to(path, 3, 0)
      |> active_buffer()

    assert Minga.Buffer.cursor(active) == {3, 0}
  end

  test "focus_buffer/2 switches to the window showing the target buffer" do
    state = base_state(content: "first file")
    original_buffer = active_buffer(state)
    original_window = state.workspace.windows.active
    new_window_id = state.workspace.windows.next_id
    state = MingaEditor.Commands.Movement.execute(state, :split_vertical)

    second_buffer =
      start_supervised!({Minga.Buffer.Process, content: "second file"}, id: {:buffer, make_ref()})

    windows =
      MingaEditor.State.Windows.replace_window(
        state.workspace.windows,
        new_window_id,
        %{
          Map.fetch!(state.workspace.windows.map, new_window_id)
          | buffer: second_buffer,
            content: {:buffer, second_buffer}
        }
      )

    state =
      state
      |> then(fn state ->
        %{state | workspace: MingaEditor.Session.State.set_windows(state.workspace, windows)}
      end)
      |> MingaEditor.WindowFocus.focus(new_window_id)

    assert EditorAPI.focus_buffer(state, original_buffer).workspace.windows.active ==
             original_window
  end

  test "focus_buffer/2 returns state unchanged when no window shows the buffer" do
    state = base_state(content: "hello")
    fake_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(fake_pid, :stop) end)

    assert EditorAPI.focus_buffer(state, fake_pid).workspace.windows.active ==
             state.workspace.windows.active
  end

  defp active_buffer(state), do: state.workspace.buffers.active

  defp write_temp_file(prefix, content) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end

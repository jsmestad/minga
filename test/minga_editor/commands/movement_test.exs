defmodule MingaEditor.Commands.MovementTest do
  @moduledoc """
  Editor GenServer smoke coverage for movement routing.

  The detailed movement behavior lives at cheaper layers:

  * Layer 0 key dispatch lives in `test/minga/mode/normal_movement_dispatch_test.exs`.
  * Layer 1 command/state-handler cursor outcomes live in `test/minga_editor/commands/movement_command_test.exs`.
  * This file keeps smoke checks that prove keypresses reach the editor command path.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor
  alias MingaEditor.Extension.Sidebar

  @sync_timeout 15_000
  @ctrl 0x02
  @arrow_left 57_350
  @arrow_right 57_351
  @space 32

  defp start_editor(content \\ "hello\nworld\nfoo", width \\ 40, height \\ 10) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"movement_events_#{id}"
    project_root = isolated_project_root(id)
    start_supervised!({Minga.Events, name: events_registry})
    sidebar_registry = private_sidebar_registry(id)

    {:ok, buffer} = BufferProcess.start_link(content: content, events_registry: events_registry)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{id}",
        port_manager: nil,
        buffer: buffer,
        width: width,
        height: height,
        editing_model: :vim,
        events_registry: events_registry,
        sidebar_registry: sidebar_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    {editor, buffer}
  end

  defp private_sidebar_registry(id) do
    name = :"movement_sidebars_#{id}"
    start_supervised!({Sidebar, name: name, notify: false})
    name
  end

  defp isolated_project_root(id) do
    root = Path.join(System.tmp_dir!(), "minga-movement-#{id}")
    File.mkdir_p!(root)
    root
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor, @sync_timeout)
    :ok
  end

  describe "editor movement routing" do
    test "movement keypresses reach the command executor" do
      {editor, buffer} = start_editor("hello")

      assert :ok = send_key(editor, ?l)

      assert BufferProcess.cursor(buffer) == {0, 1}
    end

    test "count prefixes reach mode dispatch and command execution" do
      {editor, buffer} = start_editor("hello world")

      assert :ok = send_key(editor, ?3)
      assert :ok = send_key(editor, ?l)

      assert BufferProcess.cursor(buffer) == {0, 3}
    end

    test "ctrl page keys reach scroll command execution" do
      {editor, buffer} = start_editor(lines(0..29))

      assert :ok = send_key(editor, ?d, @ctrl)

      assert BufferProcess.cursor(buffer) == {4, 0}
    end

    test "insert-mode arrow keys route through insert movement semantics" do
      {editor, buffer} = start_editor("ab\ncd")

      assert :ok = send_key(editor, ?i)
      assert :ok = send_key(editor, @arrow_right)
      assert :ok = send_key(editor, @arrow_right)
      assert :ok = send_key(editor, @arrow_right)
      assert BufferProcess.cursor(buffer) == {1, 0}

      assert :ok = send_key(editor, @arrow_left)
      assert BufferProcess.cursor(buffer) == {0, 2}
    end
  end

  describe "editor command routing under ambient events" do
    test "default bus tool prompts cannot interrupt movement dispatch" do
      {editor, buffer} = start_editor("hello")

      Minga.Events.broadcast(:tool_missing, %Minga.Events.ToolMissingEvent{command: "rg"})
      assert :ok = send_key(editor, ?l)

      assert BufferProcess.cursor(buffer) == {0, 1}
    end
  end

  describe "leader command smoke checks" do
    test "find_file command resolves without crashing" do
      {editor, _buffer} = start_editor()

      assert :ok = send_key(editor, @space)
      assert :ok = send_key(editor, ?f)
      assert :ok = send_key(editor, ?f)
    end

    test "buffer_list command resolves without crashing" do
      {editor, _buffer} = start_editor()

      assert :ok = send_key(editor, @space)
      assert :ok = send_key(editor, ?b)
      assert :ok = send_key(editor, ?b)
    end
  end

  defp lines(range), do: Enum.map_join(range, "\n", &"line #{&1}")
end

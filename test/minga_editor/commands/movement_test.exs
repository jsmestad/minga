defmodule MingaEditor.Commands.MovementTest do
  @moduledoc """
  Editor GenServer smoke coverage for movement routing.

  The former full-stack movement assertions are classified into lower layers:

  * Layer 0 key dispatch lives in `test/minga/mode/normal_movement_dispatch_test.exs`.
  * Layer 1 command/state-handler cursor outcomes live in `test/minga_editor/commands/movement_command_test.exs`.
  * This file keeps only smoke checks that prove keypresses reach the editor command path.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor

  @sync_timeout 15_000
  @ctrl 0x02
  @arrow_left 57_350
  @arrow_right 57_351

  defp start_editor(content) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"movement_events_#{id}"
    project_root = isolated_project_root(id)
    start_supervised!({Minga.Events, name: events_registry})

    {:ok, buffer} = BufferProcess.start_link(content: content, events_registry: events_registry)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{id}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim,
        events_registry: events_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    {editor, buffer}
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

  describe "Editor GenServer smoke — movement routing" do
    test "normal movement key reaches the movement command path" do
      {editor, buffer} = start_editor("hello")

      send_key(editor, ?l)

      assert BufferProcess.cursor(buffer) == {0, 1}
    end

    test "count prefix reaches the mode dispatch and command executor" do
      {editor, buffer} = start_editor("hello world")

      send_key(editor, ?3)
      send_key(editor, ?l)

      assert BufferProcess.cursor(buffer) == {0, 3}
    end

    test "normal-mode ctrl page key reaches the scroll command path" do
      {editor, buffer} = start_editor(lines(0..29))

      send_key(editor, ?d, @ctrl)

      assert BufferProcess.cursor(buffer) == {4, 0}
    end

    test "insert-mode arrow keys route through insert movement semantics" do
      {editor, buffer} = start_editor("ab\ncd")

      send_key(editor, ?i)
      send_key(editor, @arrow_right)
      send_key(editor, @arrow_right)
      send_key(editor, @arrow_right)
      assert BufferProcess.cursor(buffer) == {1, 0}

      send_key(editor, @arrow_left)
      assert BufferProcess.cursor(buffer) == {0, 2}
    end

    test "events on the default bus do not interrupt movement dispatch" do
      {editor, buffer} = start_editor("hello")

      Minga.Events.broadcast(:tool_missing, %Minga.Events.ToolMissingEvent{command: "rg"})
      send_key(editor, ?l)

      assert BufferProcess.cursor(buffer) == {0, 1}
    end
  end

  defp lines(range), do: Enum.map_join(range, "\n", &"line #{&1}")
end

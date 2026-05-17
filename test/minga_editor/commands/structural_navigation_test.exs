defmodule MingaEditor.Commands.StructuralNavigationTest do
  # Starts the real parser Port under its global production name, so these tests must not run concurrently.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Parser.Manager, as: ParserManager
  alias MingaEditor
  alias MingaEditor.State, as: EditorState

  @moduletag timeout: 15_000
  @sync_timeout 15_000
  @alt 0x04

  setup do
    start_supervised!({ParserManager, name: ParserManager, parser_path: parser_path()})
    :ok
  end

  test "Alt+h moves to parent AST node and reports the node type" do
    {editor, buffer} = start_editor("function add(a, b) {\n  return a + b;\n}\n")
    BufferProcess.move_to(buffer, {0, 20})

    state = send_key(editor, ?h, @alt)

    assert BufferProcess.cursor(buffer) == {0, 0}
    assert EditorState.status_msg(state) == "→ function_declaration"
  end

  test "Alt+l moves to the first child AST node" do
    {editor, buffer} = start_editor("function add(a, b) { return a + b; }\n")
    BufferProcess.move_to(buffer, {0, 0})

    state = send_key(editor, ?l, @alt)

    assert BufferProcess.cursor(buffer) == {0, 9}
    assert EditorState.status_msg(state) == "→ identifier"
  end

  test "Alt+j and Alt+k move between sibling AST nodes" do
    {editor, buffer} = start_editor("f(a, b, c);")
    BufferProcess.move_to(buffer, {0, 2})

    state = send_key(editor, ?j, @alt)
    assert BufferProcess.cursor(buffer) == {0, 5}
    assert EditorState.status_msg(state) == "→ identifier"

    BufferProcess.move_to(buffer, {0, 8})
    state = send_key(editor, ?k, @alt)
    assert BufferProcess.cursor(buffer) == {0, 5}
    assert EditorState.status_msg(state) == "→ identifier"
  end

  test "structural movement keeps visual selection active" do
    {editor, buffer} = start_editor("function add(a, b) { return a + b; }\n")
    BufferProcess.move_to(buffer, {0, 0})

    send_key(editor, ?v)
    state = send_key(editor, ?l, @alt)

    assert BufferProcess.cursor(buffer) == {0, 9}
    assert Minga.Editing.mode(state) == :visual
    assert MingaEditor.Editing.visual_anchor(state) == {0, 0}
    assert EditorState.status_msg(state) == "→ identifier"
  end

  defp start_editor(content) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"structural_nav_events_#{id}"
    project_root = isolated_project_root(id)
    start_supervised!({Minga.Events, name: events_registry})

    {:ok, buffer} =
      BufferProcess.start_link(
        content: content,
        events_registry: events_registry,
        filetype: :javascript
      )

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"structural_nav_editor_#{id}",
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
    root = Path.join(System.tmp_dir!(), "minga-structural-nav-#{id}")
    File.mkdir_p!(root)
    root
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    :sys.get_state(editor, @sync_timeout)
  end

  defp parser_path do
    Application.app_dir(:minga, "priv/minga-parser")
  end
end

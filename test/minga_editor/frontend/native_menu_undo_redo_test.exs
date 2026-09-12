defmodule MingaEditor.Frontend.NativeMenuUndoRedoTest do
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion
  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.SignatureHelpWorkflow
  alias MingaEditor.SignatureHelp
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload

  test "native menu Undo and Redo use buffer history while Vim Insert remains active" do
    ctx = start_editor("")
    send_key_sync(ctx, ?i)
    send_key_sync(ctx, ?a)
    before_undo = send_key_sync(ctx, ?b)

    assert Buffer.content(ctx.buffer) == "ab"
    assert Buffer.cursor(ctx.buffer) == {0, 2}
    assert before_undo.workspace.editing.mode == :insert
    assert BufferProcess.last_undo_source(ctx.buffer) == :user

    undone = send_native_menu_command(ctx, "undo")

    assert Buffer.content(ctx.buffer) == ""
    assert Buffer.cursor(ctx.buffer) == {0, 0}
    assert undone.workspace.editing == before_undo.workspace.editing
    assert undone.interaction.editing_model == :vim
    assert undone.shell_runtime.state.modal == before_undo.shell_runtime.state.modal
    assert BufferProcess.last_undo_source(ctx.buffer) == nil
    assert BufferProcess.last_redo_source(ctx.buffer) == :user

    redone = send_native_menu_command(ctx, "redo")

    assert Buffer.content(ctx.buffer) == "ab"
    assert Buffer.cursor(ctx.buffer) == {0, 2}
    assert redone.workspace.editing == before_undo.workspace.editing
    assert redone.interaction.editing_model == :vim
    assert redone.shell_runtime.state.modal == before_undo.shell_runtime.state.modal
    assert BufferProcess.last_undo_source(ctx.buffer) == :user
    assert BufferProcess.last_redo_source(ctx.buffer) == nil

    send_key_sync(ctx, ?c)
    assert Buffer.content(ctx.buffer) == "abc"
    assert editor_mode(ctx) == :insert
  end

  test "native menu Undo and Redo use buffer history in CUA without changing editing model" do
    ctx = start_editor("", editing_model: :cua)
    send_key_sync(ctx, ?a)
    before_undo = send_key_sync(ctx, ?b)

    assert Buffer.content(ctx.buffer) == "ab"
    assert Buffer.cursor(ctx.buffer) == {0, 2}
    assert before_undo.interaction.editing_model == :cua
    assert BufferProcess.last_undo_source(ctx.buffer) == :user

    undone = send_native_menu_command(ctx, "undo")

    assert Buffer.content(ctx.buffer) == ""
    assert Buffer.cursor(ctx.buffer) == {0, 0}
    assert undone.workspace.editing == before_undo.workspace.editing
    assert undone.interaction.editing_model == :cua
    assert undone.shell_runtime.state.modal == before_undo.shell_runtime.state.modal
    assert BufferProcess.last_redo_source(ctx.buffer) == :user

    redone = send_native_menu_command(ctx, "redo")

    assert Buffer.content(ctx.buffer) == "ab"
    assert Buffer.cursor(ctx.buffer) == {0, 2}
    assert redone.workspace.editing == before_undo.workspace.editing
    assert redone.interaction.editing_model == :cua
    assert redone.shell_runtime.state.modal == before_undo.shell_runtime.state.modal
    assert BufferProcess.last_undo_source(ctx.buffer) == :user
    assert BufferProcess.last_redo_source(ctx.buffer) == nil

    send_key_sync(ctx, ?c)
    assert Buffer.content(ctx.buffer) == "abc"
    assert editor_state(ctx).interaction.editing_model == :cua
  end

  test "native menu Undo and Redo preserve Vim Normal and Visual modes" do
    ctx = start_editor("")
    send_key_sync(ctx, ?i)
    send_key_sync(ctx, ?x)
    normal = send_key_sync(ctx, 27)

    assert normal.workspace.editing.mode == :normal
    assert Buffer.content(ctx.buffer) == "x"

    undone_normal = send_native_menu_command(ctx, "undo")
    assert Buffer.content(ctx.buffer) == ""
    assert undone_normal.workspace.editing == normal.workspace.editing

    redone_normal = send_native_menu_command(ctx, "redo")
    assert Buffer.content(ctx.buffer) == "x"
    assert redone_normal.workspace.editing == normal.workspace.editing

    visual = send_key_sync(ctx, ?v)
    assert visual.workspace.editing.mode == :visual

    undone_visual = send_native_menu_command(ctx, "undo")
    assert Buffer.content(ctx.buffer) == ""
    assert undone_visual.workspace.editing == visual.workspace.editing

    redone_visual = send_native_menu_command(ctx, "redo")
    assert Buffer.content(ctx.buffer) == "x"
    assert redone_visual.workspace.editing == visual.workspace.editing
  end

  test "native menu Undo and Redo leave empty history unchanged" do
    ctx = start_editor("unchanged")
    before = editor_state(ctx)
    version = Buffer.version(ctx.buffer)

    after_undo = send_native_menu_command(ctx, "undo")
    after_redo = send_native_menu_command(ctx, "redo")

    assert Buffer.content(ctx.buffer) == "unchanged"
    assert Buffer.cursor(ctx.buffer) == {0, 0}
    assert Buffer.version(ctx.buffer) == version
    assert after_undo.workspace.editing == before.workspace.editing
    assert after_redo.workspace.editing == before.workspace.editing
    assert BufferProcess.last_undo_source(ctx.buffer) == nil
    assert BufferProcess.last_redo_source(ctx.buffer) == nil
  end

  for {label, editing_model} <- [{"Vim Insert", :vim}, {"CUA", :cua}] do
    test "native menu Undo dismisses active completion before the next Enter in #{label}" do
      ctx = start_editor("", editing_model: unquote(editing_model))

      if unquote(editing_model) == :vim do
        send_key_sync(ctx, ?i)
      end

      send_key_sync(ctx, ?a)
      send_key_sync(ctx, ?b)
      install_completion(ctx, "obsolete")

      assert %Completion{} = ModalWorkflow.completion(editor_state(ctx))

      undone = send_native_menu_command(ctx, "undo")

      assert Buffer.content(ctx.buffer) == ""
      assert ModalWorkflow.completion(undone) == nil

      send_key_sync(ctx, 13)
      assert Buffer.content(ctx.buffer) == "\n"
    end
  end

  test "native menu Undo dismisses active signature help" do
    ctx = start_editor("")
    send_key_sync(ctx, ?i)
    send_key_sync(ctx, ?a)
    install_signature_help(ctx)

    assert %SignatureHelp{} = editor_state(ctx).shell_runtime.state.signature_help

    undone = send_native_menu_command(ctx, "undo")

    assert Buffer.content(ctx.buffer) == ""
    assert undone.shell_runtime.state.signature_help == nil
    assert undone.workspace.editing.mode == :insert
  end

  defp send_native_menu_command(ctx, name) do
    payload =
      <<Opcodes.gui_action(), Opcodes.gui_action_execute_command(), byte_size(name)::16,
        name::binary>>

    assert {:ok, {:gui_action, action}} = Protocol.decode_event(payload)
    send(ctx.editor, {:minga_input, {:gui_action, action}})
    editor_state(ctx)
  end

  defp install_completion(ctx, insert_text) do
    item = %{
      label: insert_text,
      insert_text: insert_text,
      filter_text: insert_text,
      kind: :text,
      detail: "",
      documentation: "",
      sort_text: insert_text,
      text_edit: nil,
      raw: nil
    }

    :sys.replace_state(ctx.editor, fn state ->
      owner = state.shell_runtime.state.tab_bar.active_id
      completion = Completion.new([item], {0, 0})
      payload = CompletionPayload.new(owner, completion: completion)
      ModalWorkflow.open(state, {:completion, payload})
    end)
  end

  defp install_signature_help(ctx) do
    signature_help =
      SignatureHelp.from_response(
        %{"signatures" => [%{"label" => "obsolete(arg)", "parameters" => []}]},
        0,
        0
      )

    :sys.replace_state(ctx.editor, &SignatureHelpWorkflow.show(&1, signature_help))
  end
end

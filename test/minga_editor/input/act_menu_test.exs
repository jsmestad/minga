defmodule MingaEditor.Input.ActMenuTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion
  alias MingaEditor.CompletionHandling
  alias MingaEditor.Input.ActMenu, as: ActMenuInput
  alias MingaEditor.Input.Router
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.{ActMenu, ActMenuWorkflow, ModalWorkflow, NoticeWorkflow}
  alias MingaEditor.Shell.Traditional.CodeHoverWorkflow
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  test "one contiguous twist names all 48 authored lines, not its two internal units" do
    content = String.duplicate("before\n", 52)
    state = TestHelpers.base_state(content: content)
    buffer = state.workspace.buffers.active
    replace(buffer, {0, 0}, 24 * 7, String.duplicate("FIRST!\n", 24), "task")
    replace(buffer, {24, 0}, 24 * 7, String.duplicate("SECOND\n", 24), "task")
    change(buffer, 50, "LATER!", "other")
    :ok = Buffer.move_to(buffer, {25, 1})
    open = ActMenuWorkflow.open_file(state, :caret)

    assert %{title: "○ Minga’s change · 48 lines · unreviewed", lead: [keep, reject]} =
             open |> ActMenuWorkflow.current() |> ActMenu.model()

    assert keep.label == "Keep change"
    assert reject.label == "Reject change"

    assert {:handled, kept} = ActMenuInput.handle_key(open, ?y, 0)
    assert NoticeWorkflow.message(kept) == "Kept 1 Minga change"
    assert Buffer.prepare_review(buffer, {:task, {:minga, "task"}}) == :empty
    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:task, {:minga, "other"}})
  end

  test "a Visual selection of one 48-line twist offers one change with whole-unit authority" do
    ctx = start_editor(String.duplicate("before\n", 52))
    buffer = active_buffer(ctx)
    replace(buffer, {0, 0}, 24 * 7, String.duplicate("FIRST!\n", 24), "task")
    replace(buffer, {24, 0}, 24 * 7, String.duplicate("SECOND\n", 24), "task")
    change(buffer, 50, "LATER!", "other")
    :ok = Buffer.move_to(buffer, {0, 0})
    send_keys_sync(ctx, "V")
    :ok = Buffer.move_to(buffer, {47, 0})

    state = send_keys_sync(ctx, "g.")

    assert %{title: "○ Minga’s change · 48 lines · unreviewed", lead: [keep, reject]} =
             state |> ActMenuWorkflow.current() |> ActMenu.model()

    assert keep.label == "Keep change"
    assert reject.label == "Reject change"
    send_keys_sync(ctx, "y")
    assert Buffer.prepare_review(buffer, {:task, {:minga, "task"}}) == :empty
    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:task, {:minga, "other"}})
  end

  test "a deletion-only offer describes the removed text rather than its surviving anchor row" do
    state = TestHelpers.base_state(content: "gone\nstill here\n")
    buffer = state.workspace.buffers.active
    replace(buffer, {0, 0}, 5, "", "task")

    assert %{title: "○ Minga’s change · 5 bytes removed · unreviewed"} =
             state
             |> ActMenuWorkflow.open_file(:caret)
             |> ActMenuWorkflow.current()
             |> ActMenu.model()
  end

  test "Enter keeps the exact grouped review at the caret, not the later ribbon" do
    ctx = start_editor("one\ntwo\ngap\nfour\n")
    buffer = active_buffer(ctx)
    change(buffer, 0, "ONE", "task")
    change(buffer, 1, "TWO", "task")
    change(buffer, 3, "FOUR", "other")
    :ok = Buffer.move_to(buffer, {1, 0})

    send_keys_sync(ctx, "g.<CR>")

    assert Buffer.prepare_review(buffer, {:task, {:minga, "task"}}) == :empty
    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:task, {:minga, "other"}})
    assert buffer_content(ctx) == "ONE\nTWO\ngap\nFOUR\n"
    assert buffer_cursor(ctx) == {1, 0}
  end

  test "g. in a focused hover opens the review for its exact source and preserves Normal mode" do
    ctx = start_editor("one\ngap\nthree\n")
    buffer = active_buffer(ctx)
    change(buffer, 0, "ONE", "other")
    change(buffer, 2, "THREE", "hovered")
    :ok = Buffer.move_to(buffer, {2, 0})

    hovered = send_keys_sync(ctx, "KK")

    assert %MingaEditor.HoverPopup{focused: true, code_source: %{anchor: anchor}} =
             MingaEditor.Shell.Runtime.state(hovered.shell_runtime).hover_popup

    state = send_keys_sync(ctx, "g.")

    assert %{title: "○ Minga’s change · 1 line · unreviewed", anchor: ^anchor} =
             state |> ActMenuWorkflow.current() |> ActMenu.model()

    send_keys_sync(ctx, "y")
    assert Buffer.prepare_review(buffer, {:task, {:minga, "hovered"}}) == :empty
    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:task, {:minga, "other"}})
    assert buffer_cursor(ctx) == {2, 0}
    assert editor_mode(ctx) == :normal
  end

  test "g. does not retarget a hover after its source revision changes" do
    ctx = start_editor("one\ngap\nthree\n")
    buffer = active_buffer(ctx)
    change(buffer, 2, "THREE", "hovered")
    :ok = Buffer.move_to(buffer, {2, 0})
    hovered_state = send_keys_sync(ctx, "K")

    assert %MingaEditor.HoverPopup{code_source: %{position: {2, 0}}} =
             MingaEditor.Shell.Runtime.state(hovered_state.shell_runtime).hover_popup

    change(buffer, 0, "ONE", "other")

    assert hovered_state
           |> MingaEditor.Input.Router.dispatch(?g, 0)
           |> MingaEditor.Input.Router.dispatch(?., 0)
           |> ActMenuWorkflow.current() == nil

    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:task, {:minga, "hovered"}})
  end

  test "g. refuses a hover that scrolls away between its two keys" do
    ctx = start_editor("one\ngap\nthree\n")
    buffer = active_buffer(ctx)
    change(buffer, 2, "THREE", "hovered")
    :ok = Buffer.move_to(buffer, {2, 0})
    state = send_keys_sync(ctx, "K")
    prefixed = Router.dispatch(state, ?g, 0)
    window = SessionState.active_window_struct(prefixed.workspace)
    viewport = Viewport.put_top(window.viewport, 1)
    next_window = Window.set_viewport(window, viewport)
    windows = Windows.replace_window(prefixed.workspace.windows, window.id, next_window)
    workspace = SessionState.set_windows(prefixed.workspace, windows)
    departed = CodeHoverWorkflow.reconcile_source(%{prefixed | workspace: workspace})

    refused = Router.dispatch(departed, ?., 0)
    assert ActMenuWorkflow.current(refused) == nil
    assert Buffer.cursor(buffer) == {2, 0}
    assert ActMenuWorkflow.current(refused |> Router.dispatch(?g, 0) |> Router.dispatch(?., 0))
  end

  test "a delayed hover footer click cannot act on the replacement popup" do
    ctx = start_editor("one\ngap\nthree\n")
    buffer = active_buffer(ctx)
    change(buffer, 0, "ONE", "first")
    change(buffer, 2, "THREE", "second")
    :ok = Buffer.move_to(buffer, {0, 0})
    first = send_keys_sync(ctx, "K")
    stale_offer = MingaEditor.Shell.Runtime.state(first.shell_runtime).hover_popup.offer_id
    send_keys_sync(ctx, "<Esc>")
    :ok = Buffer.move_to(buffer, {2, 0})
    second = send_keys_sync(ctx, "K")
    offer = MingaEditor.Shell.Runtime.state(second.shell_runtime).hover_popup.offer_id

    stale =
      MingaEditor.Handlers.GuiActionHandler.dispatch(
        second,
        {:hover_open_action, stale_offer, :actions}
      )

    assert ActMenuWorkflow.current(stale) == nil

    current =
      MingaEditor.Handlers.GuiActionHandler.dispatch(stale, {:hover_open_action, offer, :actions})

    assert %{title: "○ Minga’s change · 1 line · unreviewed"} =
             current |> ActMenuWorkflow.current() |> ActMenu.model()
  end

  test "a cursor hover does not act after the caret moves within the same viewport" do
    ctx = start_editor("one\ngap\nthree\n")
    buffer = active_buffer(ctx)
    change(buffer, 0, "ONE", "first")
    :ok = Buffer.move_to(buffer, {0, 0})
    state = send_keys_sync(ctx, "K")
    %{offer_id: offer} = MingaEditor.Shell.Runtime.state(state.shell_runtime).hover_popup

    :ok = Buffer.move_to(buffer, {2, 0})

    stale =
      MingaEditor.Handlers.GuiActionHandler.dispatch(state, {:hover_open_action, offer, :actions})

    assert ActMenuWorkflow.current(stale) == nil
    assert MingaEditor.Shell.Runtime.state(stale.shell_runtime).hover_popup == nil
    assert Buffer.cursor(buffer) == {2, 0}
  end

  test "filtering down to Reject cannot make Enter reject a visual selection" do
    ctx = start_editor("one\ngap\ntwo\n")
    buffer = active_buffer(ctx)
    change(buffer, 0, "ONE", "first")
    change(buffer, 2, "TWO", "second")
    :ok = Buffer.move_to(buffer, {0, 0})

    selection = send_keys_sync(ctx, "Vjjg.")

    assert %{title: "○ 2 Minga changes · 2 lines · unreviewed"} =
             selection |> ActMenuWorkflow.current() |> ActMenu.model()

    send_keys_sync(ctx, "/Reject<CR><Esc>")
    assert buffer_content(ctx) == "ONE\ngap\nTWO\n"
    assert editor_mode(ctx) == :visual
    assert buffer_cursor(ctx) == {2, 0}

    send_keys_sync(ctx, "g.nn")
    assert buffer_content(ctx) == "ONE\ngap\nTWO\n"
    assert editor_mode(ctx) == :visual

    send_keys_sync(ctx, "g.ny")
    assert buffer_content(ctx) == "one\ngap\ntwo\n"
  end

  test "closing the menu from Insert restores typing at the original point" do
    ctx = start_editor("hi")
    send_keys_sync(ctx, "i")
    send_key_sync(ctx, ?., 0x02)
    send_keys_sync(ctx, "/copy<Esc>X")

    assert editor_mode(ctx) == :insert
    assert buffer_content(ctx) == "Xhi"
  end

  @tag :tmp_dir
  test "g. opens the selected tree entry and leaves gg available for navigation", %{tmp_dir: root} do
    first = Path.join(root, "a.txt")
    last = Path.join(root, "z.txt")
    File.write!(first, "first")
    File.write!(last, "last")
    ctx = start_editor("first", file_path: first, project_root: root)
    send_keys_sync(ctx, "<Space>op")

    wait_until(ctx, fn state -> FileTreeState.status(state.workspace.file_tree) == :ready end)
    send_keys_sync(ctx, "ggj")
    state = send_keys_sync(ctx, "g.")
    assert %{title: "z.txt"} = state |> ActMenuWorkflow.current() |> ActMenu.model()

    first_state = send_keys_sync(ctx, "<Esc>ggg.")
    assert %{title: "a.txt"} = first_state |> ActMenuWorkflow.current() |> ActMenu.model()
  end

  test "a late completion dismissal does not return menu typing to the buffer" do
    state = TestHelpers.base_state(content: "one")
    state = %{state | workspace: SessionState.transition_mode(state.workspace, :insert)}
    completion = CompletionPayload.new(1, completion: Completion.new([], {0, 0}))
    state = ModalWorkflow.open(state, {:completion, completion})
    {:handled, open} = ActMenuWorkflow.open_for_typing(state)

    after_completion = CompletionHandling.dismiss(open)
    assert {:handled, filtered} = ActMenuInput.handle_key(after_completion, ?x, 0)
    assert %{query: "x"} = filtered |> ActMenuWorkflow.current() |> ActMenu.model()
    assert Buffer.content(state.workspace.buffers.active) == "one"
  end

  test "explicitly closing the editing modal also clears its act menu" do
    state = TestHelpers.base_state(content: "one")
    state = %{state | workspace: SessionState.transition_mode(state.workspace, :insert)}
    completion = CompletionPayload.new(1, completion: Completion.new([], {0, 0}))
    state = ModalWorkflow.open(state, {:completion, completion})
    {:handled, open} = ActMenuWorkflow.open_for_typing(state)

    assert open |> ModalWorkflow.close() |> ActMenuWorkflow.current() == nil
  end

  defp change(buffer, row, text, task),
    do: replace(buffer, {row, 0}, byte_size(text), text, task)

  defp replace(buffer, position, removed, text, task) do
    source = EditSource.minga(task, text)

    assert {:ok, _receipt} =
             BufferProcess.replace_byte_range_if_version(
               buffer,
               Buffer.version(buffer),
               position,
               removed,
               text,
               source
             )
  end
end

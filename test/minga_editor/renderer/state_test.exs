defmodule MingaEditor.Renderer.StateTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.RenderModel.Window.Row
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.AckLease
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.RecoveryHandler
  alias MingaEditor.Renderer.State
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Renderer.TextPresentations
  alias Minga.Core.WidthOracle.Monospace
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.RenderModel.Window.ReviewLayout
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Theme
  alias MingaEditor.Window, as: EditorWindow

  test "new state starts with idle frame credit" do
    assert State.new([]).frame_credit == :idle
    refute State.rendering?(State.new([]))
  end

  test "scheduled credit consumes only exact render token" do
    state = State.new([])
    attempt = attempt(10)
    token = make_ref()

    scheduled = State.schedule_frame(state, attempt, token)

    assert State.rendering?(scheduled)
    assert scheduled.frame_credit == {:scheduled, token, attempt, 0, nil}
    assert State.consume_render_token(scheduled, make_ref()) == :stale
    assert State.consume_render_token(scheduled, token) == {:ok, scheduled, attempt, 0}
  end

  test "coalescing preserves scheduled work and reports replaced successor" do
    state = State.schedule_frame(State.new([]), attempt(10), make_ref())
    successor_11 = attempt(11)
    successor_12 = attempt(12)

    assert {:coalesced, coalesced, nil} = State.coalesce_frame(state, successor_11)
    assert {:scheduled, _token, %FrameAttempt{seq: 10}, 0, ^successor_11} = coalesced.frame_credit

    assert {:coalesced, latest, ^successor_11} = State.coalesce_frame(coalesced, successor_12)
    assert {:scheduled, _token, %FrameAttempt{seq: 10}, 0, ^successor_12} = latest.frame_credit
  end

  test "awaiting acknowledgement preserves successor" do
    state = State.schedule_frame(State.new([]), attempt(10), make_ref())
    successor = attempt(11)
    {:coalesced, state, nil} = State.coalesce_frame(state, successor)
    lease = AckLease.start(attempt(10), input(), 1_000)

    awaiting = State.await_ack(state, lease)

    assert awaiting.frame_credit == {:awaiting_ack, lease, successor}
    assert State.awaiting_lease(awaiting) == lease
  end

  test "advance credit clears busy phase and returns successor when present" do
    scheduled = State.schedule_frame(State.new([]), attempt(10), make_ref())
    assert State.advance_credit(scheduled) == {:idle, %{scheduled | frame_credit: :idle}}

    successor = attempt(11)
    {:coalesced, awaiting_source, nil} = State.coalesce_frame(scheduled, successor)
    lease = AckLease.start(attempt(10), input(), 1_000)
    awaiting = State.await_ack(awaiting_source, lease)

    assert {:schedule, cleared, ^successor} = State.advance_credit(awaiting)
    assert cleared.frame_credit == :idle
  end

  test "retry replaces only token and increments retry count" do
    new_token = make_ref()
    attempt = attempt(10)

    state =
      State.new([])
      |> State.schedule_frame(attempt, make_ref())
      |> State.retry_scheduled_frame(new_token)

    assert state.frame_credit == {:scheduled, new_token, attempt, 1, nil}
  end

  test "latest successor selects queued work or retains the fallback identity" do
    fallback = attempt(10)
    successor = attempt(11)

    state = State.schedule_frame(State.new([]), fallback, make_ref())
    {:coalesced, state, nil} = State.coalesce_frame(state, successor)

    assert State.latest_successor(state, fallback) == successor

    assert State.latest_successor(State.new([]), fallback) == fallback
  end

  test "fresh recovery context only raises the local floor and does not renumber pending work" do
    pending = attempt(20)

    for {floor, expected_next} <- [{1, 21}, {100, 100}] do
      state =
        State.new(recovery_reserver: fn -> {2, floor} end, next_frame_seq: 21)
        |> State.schedule_frame(pending, make_ref())

      assert {reserved, {2, ^floor}} = State.reserve_recovery_context(state)
      assert reserved.next_frame_seq == expected_next
      assert reserved.frame_credit == state.frame_credit
    end
  end

  test "rejection recovery preserves the visible lease until recovered activation" do
    old = presentation(1, 101, 3, "old")
    registry = TextPresentations.acknowledge(TextPresentations.new(), [old])
    assert {:ok, registry} = TextPresentations.activate(registry, 1, old.presentation_id)

    state =
      %{State.new(recovery_reserver: fn -> {2, 1} end) | text_presentations: registry}

    reader = State.text_interaction_reader(state)
    assert {:noreply, recovered} = RecoveryHandler.transaction(state, attempt(10))

    assert {:ok, %TextTarget{line: 3}} = Reader.resolve(reader, event(old))

    replacement = presentation(1, 102, 4, "recovered")

    admitted =
      TextPresentations.acknowledge(recovered.text_presentations, [replacement])

    recovered = %{recovered | text_presentations: admitted}

    assert {:ok, recovered} =
             State.text_presentation_state(
               recovered,
               1,
               replacement.presentation_id,
               :active
             )

    assert {:ok, %TextTarget{line: 4}} = Reader.resolve(reader, event(replacement))

    reset = State.reset_connection(recovered, 3)
    assert State.text_interaction_reader(reset) == reader
    assert {:error, :inactive} = Reader.resolve(reader, event(replacement))
  end

  test "resident input distinguishes out-of-bounds rows from unavailable row data" do
    table = :ets.new(:resident_input, [:set])
    event = event(presentation(1, 101, 3, "text"))
    reader = Reader.new(table)
    root = make_ref()
    active_key = {:active, event.window_id}
    lease_key = {:lease, event.window_id, event.presentation_id}

    :ets.insert(table, {active_key, event.presentation_id + 1})
    assert {:error, :inactive} = Reader.resolve(reader, event)

    :ets.insert(table, {active_key, event.presentation_id})
    assert {:error, :inactive} = Reader.resolve(reader, event)

    :ets.insert(table, {lease_key, {self(), 0, {:resident, root}, nil, 0}})
    assert {:error, :unavailable} = Reader.resolve(reader, %{event | row_index: 1})

    :ets.insert(table, {{:node_header, root}, {1, nil, nil, nil, nil, nil, nil}})
    assert {:error, :row_not_found} = Reader.resolve(reader, %{event | row_index: 1})
  end

  test "review rows survive frame materialization and recovery without creating buffer authority" do
    {editor, preview} = review_editor()
    input = Input.from_editor_state(editor)
    id = input.windows.active
    carrier = Map.fetch!(input.intent.windows, id)
    renderer = State.reconcile_windows(State.new([]), input.intent)
    layout = ReviewLayout.new(80, %Monospace{}, Theme.get!(:minga_default), 4)
    window = RenderWindow.materialize(id, carrier, State.window_cache(renderer, id))

    {:ok, projection, nil, window} =
      RenderWindow.project_review(window, preview, :workspace, layout)

    {window, epoch, true} = RenderWindow.prepare_render_epoch(window, :review)
    output = Input.record_render_window(input, id, window)
    renderer = State.commit_review_windows(renderer, output)
    assert renderer.resident_windows == %{}
    assert map_size(renderer.review_windows) == 1

    renderer = State.reconcile_windows(renderer, input.intent)
    window = RenderWindow.materialize(id, carrier, State.window_cache(renderer, id))

    {:ok, retained, nil, window} =
      RenderWindow.project_review(window, preview, :workspace, layout)

    assert :erts_debug.same(projection, retained)
    {_window, same_epoch, false} = RenderWindow.prepare_render_epoch(window, :review)
    assert same_epoch == epoch

    renderer = State.reset_frontend(renderer, 2)
    window = RenderWindow.materialize(id, carrier, State.window_cache(renderer, id))

    {:ok, retained, nil, window} =
      RenderWindow.project_review(window, preview, :workspace, layout)

    assert :erts_debug.same(projection, retained)
    {_window, same_epoch, true} = RenderWindow.prepare_render_epoch(window, :review)
    assert same_epoch == epoch
  end

  test "leaving review drops its cache and a replacement window cannot inherit old rows" do
    {editor, preview} = review_editor()
    input = Input.from_editor_state(editor)
    id = input.windows.active
    renderer = State.reconcile_windows(State.new([]), input.intent)
    carrier = Map.fetch!(input.intent.windows, id)
    layout = ReviewLayout.new(80, %Monospace{}, Theme.get!(:minga_default), 4)
    window = RenderWindow.materialize(id, carrier, State.window_cache(renderer, id))

    {:ok, _projection, nil, window} =
      RenderWindow.project_review(window, preview, :workspace, layout)

    renderer =
      State.commit_review_windows(renderer, Input.record_render_window(input, id, window))

    original = Windows.active_struct(editor.workspace.windows)

    replaced =
      EditorWindow.new_agent_chat(original.id, original.viewport.rows, original.viewport.cols)
      |> EditorWindow.show_agent_body(:review)

    replacement = replace_editor_window(editor, replaced) |> Input.from_editor_state()
    renderer = State.reconcile_windows(renderer, replacement.intent)
    assert State.window_cache(renderer, id).review_projection == nil

    closed =
      replace_editor_window(editor, EditorWindow.show_empty_state(original))
      |> Input.from_editor_state()

    renderer = State.reconcile_windows(renderer, closed.intent)
    assert renderer.review_windows == %{}
  end

  defp review_editor do
    editor = TestHelpers.base_state()
    original = Windows.active_struct(editor.workspace.windows)

    window =
      EditorWindow.new_agent_chat(original.id, original.viewport.rows, original.viewport.cols)

    editor = replace_editor_window(editor, window)
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "after"))

    ui =
      editor.workspace.agent_ui
      |> UIState.replace_preview(preview)
      |> UIState.set_focus(:file_viewer)

    {Workflow.install_agent_ui(editor, ui), preview}
  end

  defp replace_editor_window(editor, window) do
    windows = Windows.replace_window(editor.workspace.windows, window.id, window)
    %{editor | workspace: SessionState.set_windows(editor.workspace, windows)}
  end

  defp presentation(window_id, row_id, line, text) do
    row = %Row{
      row_id: row_id,
      row_type: :normal,
      buf_line: line,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
    }

    visual =
      VisualRow.new(
        row,
        SourceOffsetMap.new(text, text, Decorations.new(), line),
        0,
        byte_size(text),
        0
      )

    TextPresentation.new(
      window_id,
      self(),
      7,
      {:identity, row_id},
      {:windowed, {visual}},
      System.unique_integer([:positive, :monotonic])
    )
  end

  defp event(presentation) do
    {%VisualRow{row: row}} = elem(presentation.rows, 1)

    TextEvent.new(%{
      window_id: presentation.window_id,
      presentation_id: presentation.presentation_id,
      row_index: 0,
      row_id: row.row_id,
      utf16_offset: 1,
      button: :left,
      mods: 0,
      event_type: :press,
      click_count: 1,
      scroll_x: 0,
      scroll_y: 0
    })
  end

  defp attempt(seq), do: FrameAttempt.new(intent(), seq, 0)
  defp intent, do: input().intent

  defp input do
    TestHelpers.base_state()
    |> Input.from_editor_state()
  end
end

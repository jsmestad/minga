defmodule MingaEditor.Journeys.TaskReviewTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer
  alias Minga.Buffer.FileMutation
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaAgent.Tool.{Context, Invocation}
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.{TaskReviewWorkflow, Workflow}
  alias MingaEditor.State.Buffers

  @task "task-review-journey"
  @original "first\nsecond\nthird"

  @tag :tmp_dir
  test "the review opens once beside a split, previews, and confirms Keep all", %{tmp_dir: dir} do
    ctx = start_review_editor(dir)
    send_keys_sync(ctx, ":vsplit<CR>")
    send_keys_sync(ctx, "<SPC>ar")
    review = await_review(ctx, :open)
    assert Buffer.buffer_name(review) == "*minga-review*"
    assert Buffer.content(review) =~ "No changes to review."

    change(ctx.buffer, "FIRST\nsecond\nthird", "a")
    change(ctx.buffer, "FIRST\nsecond\nTHIRD", "b")
    send_keys_sync(ctx, "<SPC>ar")
    assert ^review = await_review(ctx, :open)
    assert Buffer.content(review) =~ "Change at 1:1"
    assert Buffer.content(review) =~ "Change at 3:1"

    send_keys_sync(ctx, "]h=")
    assert ^review = await_review(ctx, :diff)
    assert Buffer.content(review) =~ "- third"
    assert Buffer.content(review) =~ "+ THIRD"
    refute Buffer.content(review) =~ "+ FIRST"
    send_keys_sync(ctx, "=")
    refute Buffer.content(review) =~ "+ THIRD"

    send_keys_sync(ctx, "/n<Esc>")
    assert {[_first, _last], _, {0, 0}} = Buffer.task_review_entries(ctx.buffer, @task)

    send_keys_sync(ctx, "Yn")
    assert Buffer.content(review) =~ "Change at 3:1"
    refute Buffer.content(review) =~ "Passt."

    send_keys_sync(ctx, "Yy")
    assert ^review = await_review(ctx, :decide)
    text = Buffer.content(review)
    assert text =~ "Kept"
    assert [_] = :binary.matches(text, "Passt.")

    wait_until_screen(ctx, fn ->
      screen_contains?(ctx, "Passt.") and screen_contains?(ctx, "THIRD")
    end)

    assert Buffer.content(ctx.buffer) == "FIRST\nsecond\nTHIRD"

    send_keys_sync(ctx, "q")
    assert active_window_buffer(ctx) == ctx.buffer
  end

  @tag :tmp_dir
  test "Ex review seeds the shared quickfix list, which survives closing the review pane", %{
    tmp_dir: dir
  } do
    ctx = start_review_editor(dir)
    change(ctx.buffer, "FIRST\nsecond\nthird", "a")
    change(ctx.buffer, "FIRST\nsecond\nTHIRD", "b")
    send_keys_sync(ctx, ":Minga review<CR>")
    review = await_review(ctx, :open_with_quickfix)
    assert Buffer.buffer_name(review) == "*minga-review*"

    send_keys_sync(ctx, "q]q]q")
    assert active_window_buffer(ctx) == ctx.buffer
    assert buffer_cursor(ctx) == {2, 0}
    send_keys_sync(ctx, "[q")
    assert buffer_cursor(ctx) == {0, 0}
    assert Buffer.content(ctx.buffer) == "FIRST\nsecond\nTHIRD"

    send_keys_sync(ctx, ":cdo normal x<CR>")
    assert Buffer.content(ctx.buffer) == "IRST\nsecond\nHIRD"
  end

  @tag :tmp_dir
  test "quickfix moves display and command ownership together across files", %{tmp_dir: dir} do
    ctx = start_review_editor(dir)
    path = Path.join(dir, "second.ex")
    File.write!(path, "different")
    other = start_supervised!({Buffer, file_path: path, events_registry: ctx.events_registry})

    :sys.replace_state(ctx.editor, fn state ->
      buffers = Buffers.add_background(state.workspace.buffers, other)
      %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}
    end)

    change(ctx.buffer, "FIRST\nsecond\nthird", "first-file")
    change(other, "DIFFERENT", "second-file")
    send_keys_sync(ctx, ":Minga review<CR>")
    _review = await_review(ctx, :open_with_quickfix)
    send_keys_sync(ctx, "q:cdo normal x<CR>")

    assert active_window_buffer(ctx) == other
    assert active_buffer(ctx) == other
    assert Buffer.content(ctx.buffer) == "IRST\nsecond\nthird"
    assert Buffer.content(other) == "IFFERENT"
  end

  @tag :tmp_dir
  test "quickfix Reject decides only listed units, even when another task edited the same line",
       %{tmp_dir: dir} do
    ctx = start_review_editor(dir)
    change(ctx.buffer, "First\nsecond\nthird", "a")
    change(ctx.buffer, "FirsT\nsecond\nthird", "other", "independent")
    change(ctx.buffer, "FirsT\nsecond\nTHIRD", "b")

    send_keys_sync(ctx, ":Minga review<CR>")
    await_review(ctx, :open_with_quickfix)
    send_keys_sync(ctx, "q:cdo Minga reject<CR>")
    await_review(ctx, :decide)

    assert Buffer.content(ctx.buffer) == "firsT\nsecond\nthird"
    assert {[], nil, {0, 2}} = Buffer.task_review_entries(ctx.buffer, @task)
    assert {[_], _, {0, 0}} = Buffer.task_review_entries(ctx.buffer, "independent")
  end

  @tag :tmp_dir
  test "closing the review invalidates a pending refresh even when focus returns to the same file",
       %{tmp_dir: dir} do
    ctx = start_review_editor(dir)
    change(ctx.buffer, "FIRST\nsecond\nthird", "a")

    other_path = Path.join(dir, "background.ex")
    File.write!(other_path, "background")

    other =
      start_supervised!({Buffer, file_path: other_path, events_registry: ctx.events_registry})

    :sys.replace_state(ctx.editor, fn state ->
      buffers = Buffers.add_background(state.workspace.buffers, other)
      %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}
    end)

    send_keys_sync(ctx, "<SPC>ar")
    review = await_review(ctx, :open)
    send_keys_sync(ctx, "<CR>")
    assert active_window_buffer(ctx) == ctx.buffer

    :ok = :sys.suspend(other)

    try do
      send_keys_sync(ctx, "<SPC>ar<SPC>wh")
      assert active_window_buffer(ctx) == review
      send_keys_sync(ctx, "q")
    after
      :ok = :sys.resume(other)
    end

    assert await_review(ctx, :open) == ctx.buffer
    send_keys_sync(ctx, "<SPC>ar")
    reopened = await_review(ctx, :open)
    refute reopened == review
    assert Buffer.content(reopened) =~ "Change at 1:1"
  end

  @tag :tmp_dir
  test "force-kill closes the review instead of discarding its dirty source file", %{tmp_dir: dir} do
    ctx = start_review_editor(dir)
    change(ctx.buffer, "FIRST\nsecond\nthird", "a")
    send_keys_sync(ctx, "<SPC>ar")
    await_review(ctx, :open)

    send_keys_sync(ctx, "<SPC>bX")
    assert active_window_buffer(ctx) == ctx.buffer
    assert Buffer.content(ctx.buffer) == "FIRST\nsecond\nthird"
    assert Buffer.dirty?(ctx.buffer)
  end

  @tag :tmp_dir
  test "a Keep acknowledged outside the review updates the mounted tree", %{tmp_dir: dir} do
    ctx = start_review_editor(dir)
    change(ctx.buffer, "FIRST\nsecond\nthird", "a")
    send_keys_sync(ctx, "<SPC>ar")
    review = await_review(ctx, :open)
    refute Buffer.content(review) =~ "Passt."

    assert {:ok, target, _, 1} = Buffer.prepare_review(ctx.buffer, {:task, {:minga, @task}})
    assert :ok = Buffer.decide_review(ctx.buffer, target, :keep)

    assert ^review = await_review(ctx, :refresh)
    text = Buffer.content(review)
    assert text =~ "Kept\n  review.ex · 1 change"
    assert [_] = :binary.matches(text, "Passt.")
  end

  @tag :tmp_dir
  test "a late Keep retires its quickfix entry with the review pane closed", %{tmp_dir: dir} do
    ctx = start_review_editor(dir)
    change(ctx.buffer, "FIRST\nsecond\nthird", "a")
    send_keys_sync(ctx, ":Minga review<CR>")
    await_review(ctx, :open_with_quickfix)
    send_keys_sync(ctx, "qG")
    assert {2, _} = before = buffer_cursor(ctx)

    assert {:ok, target, _, 1} = Buffer.prepare_review(ctx.buffer, {:task, {:minga, @task}})
    assert :ok = Buffer.decide_review(ctx.buffer, target, :keep)
    assert await_review(ctx, :refresh) == ctx.buffer

    send_keys_sync(ctx, "]q")
    wait_until_screen(ctx, fn -> screen_contains?(ctx, "The quickfix list is empty") end)
    assert buffer_cursor(ctx) == before
  end

  defp start_review_editor(dir) do
    path = Path.join(dir, "review.ex")
    File.write!(path, @original)
    ctx = start_editor(@original, file_path: path)

    connection = %ConnectionSnapshot{
      target: ConnectionTarget.new(self(), @task, nil, make_ref()),
      credential_readiness: :configured,
      model_selection: nil,
      provider_phase: :running,
      operation: :idle,
      problem: nil
    }

    :sys.replace_state(ctx.editor, fn state ->
      ui = UIState.project_connection(state.workspace.agent_ui, connection)
      Workflow.install_agent_ui(state, ui)
    end)

    :erlang.trace(ctx.editor, true, [:receive])
    ctx
  end

  defp change(buffer, text, step, task \\ @task) do
    path = Buffer.file_path(buffer)
    {before, version} = Buffer.content_with_version(buffer)
    expected = FileMutation.revision(before, version, {:buffer, path})

    invocation = %Invocation{
      request_id: "request",
      checkpoint_id: "checkpoint",
      call_id: step,
      name: "edit_file",
      arguments: %{}
    }

    context =
      [project_root: Path.dirname(path)]
      |> Context.new()
      |> Context.bind_session_invocation(self(), invocation, task)

    assert {:ok, _receipt} = Context.conditional_mutate(context, path, expected, {:replace, text})
  end

  defp await_review(ctx, expected) do
    editor = ctx.editor

    assert_receive {:trace, ^editor, :receive,
                    {:effect_result, _,
                     %Outcome{
                       request: %{effect: %TaskReviewWorkflow{action: action}},
                       value: {:completed, _}
                     }}},
                   1_000

    assert if(is_tuple(action), do: elem(action, 0), else: action) == expected
    active_window_buffer(ctx)
  end
end

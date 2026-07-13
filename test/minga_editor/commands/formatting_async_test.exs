defmodule MingaEditor.Commands.FormattingAsyncTest do
  @moduledoc "Typed external-format effect application and version-safety tests."

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Formatting
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.Effects.ExternalFormat
  alias MingaEditor.Effects.ExternalFormatResult
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @effect_timeout 2_000

  test "origin creates and terminalizes feedback when the scheduler is unavailable" do
    state = base_state("defmodule Example, do: nil\n", filetype: :elixir)
    state = Formatting.format_buffer(state)

    assert feedback(state).kind == :external_format
    assert feedback(state).status == :error
    assert feedback(state).message == "Formatter scheduler unavailable"
    assert state.shell_runtime.state.notice.message == nil
  end

  test "request is latest-wins and keyed by Buffer process identity" do
    state = base_state("hello\n")
    buffer = state.workspace.buffers.active

    assert %Request{
             resource: {:buffer, ^buffer},
             policy: %{mode: :latest_wins, max_queued: 0},
             effect: %ExternalFormat{buffer: ^buffer, formatter: "cat"}
           } = ExternalFormat.request(buffer, "cat", 1)
  end

  test "completed formatting applies only to the captured buffer version" do
    state = base_state("hello world\n")
    buffer = state.workspace.buffers.active
    {state, request} = external_request(state, buffer)
    result = ExternalFormatResult.new(buffer, Buffer.version(buffer), "HELLO WORLD\n")

    {new_state, outcome} = ExternalFormat.apply(state, Outcome.completed(request, result))

    assert Buffer.content(buffer) == "HELLO WORLD\n"
    assert feedback(new_state).message == "Formatted"
    assert feedback(new_state).status == :success
    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) == nil
    assert outcome.status == :completed
  end

  test "successful replacement does not query a buffer that closes after replying" do
    buffer =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:replace_content_if_version, 0, "FORMATTED\n", :user}} ->
            GenServer.reply(from, :ok)
        end
      end)

    monitor = Process.monitor(buffer)
    state = base_state("hello\n")
    {state, request} = external_request(state, buffer)
    result = ExternalFormatResult.new(buffer, 0, "FORMATTED\n", "closed.ex")

    {new_state, outcome} = ExternalFormat.apply(state, Outcome.completed(request, result))

    assert_receive {:DOWN, ^monitor, :process, ^buffer, :normal}
    assert feedback(new_state).message == "Formatted"
    assert feedback(new_state).status == :success
    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) == nil
    assert outcome.status == :completed
  end

  test "buffer mutation makes a completed worker result stale without overwriting content" do
    state = base_state("hello world\n")
    buffer = state.workspace.buffers.active
    {state, request} = external_request(state, buffer)
    result = ExternalFormatResult.new(buffer, Buffer.version(buffer), "STALE\n")
    Buffer.replace_content(buffer, "modified\n")

    {new_state, outcome} = ExternalFormat.apply(state, Outcome.completed(request, result))

    assert Buffer.content(buffer) == "modified\n"
    assert feedback(new_state).message == "Buffer changed, format skipped"
    assert feedback(new_state).status == :stale
    assert outcome.status == :stale
    assert outcome.reason == :buffer_version_changed
  end

  test "a mutation queued after the atomic external commit is not overwritten" do
    state = base_state("hello world\n")
    buffer = state.workspace.buffers.active
    {state, request} = external_request(state, buffer)
    version = Buffer.version(buffer)
    result = ExternalFormatResult.new(buffer, version, "FORMATTED\n")
    :ok = :sys.suspend(buffer)

    task =
      Task.async(fn ->
        receive do
          :apply_result -> ExternalFormat.apply(state, Outcome.completed(request, result))
        end
      end)

    task_pid = task.pid
    1 = :erlang.trace(task_pid, true, [:send])
    send(task_pid, :apply_result)

    assert_receive {:trace, ^task_pid, :send,
                    {:"$gen_call", {_from, _tag},
                     {:replace_content_if_version, ^version, "FORMATTED\n", :user}}, ^buffer},
                   @effect_timeout

    insert_tag = make_ref()

    send(
      buffer,
      {:"$gen_call", {self(), insert_tag}, {:insert_text, "!", Minga.Buffer.EditSource.user()}}
    )

    :ok = :sys.resume(buffer)
    assert_receive {^insert_tag, :ok}, @effect_timeout
    {new_state, outcome} = Task.await(task)

    assert Buffer.content(buffer) == "!FORMATTED\n"
    assert feedback(new_state).message == "Formatted"
    assert feedback(new_state).status == :success
    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) == nil
    assert outcome.status == :completed
    assert :ok = Buffer.undo(buffer)
    assert Buffer.content(buffer) == "hello world\n"
  end

  test "read-only and closed buffers produce typed failures" do
    read_only_state = base_state("hello\n", read_only: true)
    read_only_buffer = read_only_state.workspace.buffers.active
    {read_only_state, read_only_request} = external_request(read_only_state, read_only_buffer)

    read_only_result =
      ExternalFormatResult.new(read_only_buffer, Buffer.version(read_only_buffer), "HELLO\n")

    {read_only_state, read_only_outcome} =
      ExternalFormat.apply(
        read_only_state,
        Outcome.completed(read_only_request, read_only_result)
      )

    assert Buffer.content(read_only_buffer) == "hello\n"
    assert feedback(read_only_state).message == "Buffer is read-only, format skipped"
    assert feedback(read_only_state).status == :error
    assert read_only_outcome.status == :failed
    assert read_only_outcome.reason == :read_only

    closed_state = base_state("hello\n")
    closed_buffer = closed_state.workspace.buffers.active
    {closed_state, closed_request} = external_request(closed_state, closed_buffer)

    closed_result =
      ExternalFormatResult.new(closed_buffer, Buffer.version(closed_buffer), "HELLO\n")

    monitor = Process.monitor(closed_buffer)
    Process.exit(closed_buffer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^closed_buffer, :killed}

    {closed_state, closed_outcome} =
      ExternalFormat.apply(closed_state, Outcome.completed(closed_request, closed_result))

    assert feedback(closed_state).message == "Buffer closed, format skipped"
    assert feedback(closed_state).status == :error
    assert closed_outcome.status == :failed
    assert closed_outcome.reason == :buffer_closed
  end

  test "failed, canceled, and stale outcomes have user-visible feedback" do
    state = base_state("hello\n")
    buffer = state.workspace.buffers.active
    {state, request} = external_request(state, buffer)

    {failed_state, failed} =
      ExternalFormat.apply(state, Outcome.failed(request, "formatter failed"))

    assert feedback(failed_state).message == "Format error: formatter failed"
    assert feedback(failed_state).status == :error
    assert failed.status == :failed

    {timeout_state, timeout} = ExternalFormat.apply(state, Outcome.failed(request, :timeout))
    assert feedback(timeout_state).message == "Format timed out"
    assert feedback(timeout_state).status == :timeout
    assert timeout.status == :failed

    {canceled_state, canceled} =
      ExternalFormat.apply(state, Outcome.canceled(request, :requested))

    assert feedback(canceled_state).message == "Format canceled"
    assert feedback(canceled_state).status == :canceled
    assert canceled.status == :canceled

    {stale_state, stale} =
      ExternalFormat.apply(state, Outcome.stale(Outcome.completed(request, nil), :changed))

    assert feedback(stale_state).message == "Buffer changed, format skipped"
    assert feedback(stale_state).status == :stale
    assert stale.status == :stale
  end

  test "format application preserves cursor position" do
    state = base_state("line one\nline two\nline three\n")
    buffer = state.workspace.buffers.active
    Buffer.move_to(buffer, {1, 3})
    {state, request} = external_request(state, buffer)

    result =
      ExternalFormatResult.new(
        buffer,
        Buffer.version(buffer),
        "LINE ONE\nLINE TWO\nLINE THREE\n"
      )

    {new_state, outcome} = ExternalFormat.apply(state, Outcome.completed(request, result))

    assert Buffer.content(buffer) == "LINE ONE\nLINE TWO\nLINE THREE\n"
    assert Buffer.cursor(buffer) == {1, 3}
    assert feedback(new_state).message == "Formatted"
    assert feedback(new_state).status == :success
    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) == nil
    assert outcome.status == :completed
  end

  @spec feedback(EditorState.t()) :: MingaEditor.State.Operation.t()
  defp feedback(state), do: OperationFeedback.selected(state.operation_feedback)

  @spec external_request(EditorState.t(), pid()) :: {EditorState.t(), Request.t()}
  defp external_request(state, buffer) do
    {state, operation} =
      OperationFeedback.start_in(
        state,
        :external_format,
        "buffer:" <> inspect(buffer),
        "Formatting..."
      )

    {state, ExternalFormat.request(buffer, "cat", operation.id)}
  end

  @spec base_state(String.t(), keyword()) :: EditorState.t()
  defp base_state(content, opts \\ []) do
    buffer_opts = Keyword.merge([content: content], opts)
    buffer = start_supervised!({BufferProcess, buffer_opts}, id: {:buffer, make_ref()})

    workspace = %MingaEditor.Session.State{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      }
    }

    %EditorState{port_manager: self(), workspace: workspace}
  end
end

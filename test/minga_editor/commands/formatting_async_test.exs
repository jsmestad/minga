defmodule MingaEditor.Commands.FormattingAsyncTest do
  @moduledoc "Typed external-format effect application and version-safety tests."

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Commands.Formatting
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.Effects.ExternalFormat
  alias MingaEditor.Effects.ExternalFormatResult
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
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
    assert match?({:completed, _result}, outcome.value)
  end

  test "external format continuation saves after successful scheduler result" do
    path = tmp_path("external-format-save.txt")
    File.write!(path, "hello\n")
    state = base_state("hello\n", file_path: path)
    buffer = state.workspace.buffers.active
    version = Buffer.version(buffer)
    continuation = {:save_after_format, buffer, version, :save}
    {state, request} = external_request(state, buffer, continuation)
    result = ExternalFormatResult.new(buffer, version, "HELLO\n")

    {new_state, _outcome} = ExternalFormat.apply(state, Outcome.completed(request, result))

    assert Buffer.content(buffer) == "HELLO\n"
    assert File.read!(path) == "HELLO\n"
    assert feedback(new_state).message == "Formatted"
  end

  test "delayed external save worker snapshot rejects intervening edit" do
    path = tmp_path("external-format-delayed-save.txt")
    File.write!(path, "old\n")
    state = base_state("old\n", file_path: path)
    buffer = state.workspace.buffers.active
    requested_version = Buffer.version(buffer)
    continuation = {:save_after_format, buffer, requested_version, :save}
    Buffer.replace_content(buffer, "user edit\n")
    worker_version = Buffer.version(buffer)
    {state, request} = external_request(state, buffer, continuation)
    result = ExternalFormatResult.new(buffer, worker_version, "FORMATTED NEW\n")

    {new_state, outcome} = ExternalFormat.apply(state, Outcome.completed(request, result))

    assert Buffer.content(buffer) == "user edit\n"
    assert File.read!(path) == "old\n"
    assert feedback(new_state).status == :stale
    assert outcome.value == {:stale, :buffer_version_changed}

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
             "Save skipped: buffer changed during formatting"
  end

  test "edit after formatter commit does not bless a newer save revision" do
    path = tmp_path("external-format-commit-race.txt")
    File.write!(path, "old\n")
    state = base_state("old\n", file_path: path)
    buffer = state.workspace.buffers.active
    requested_version = Buffer.version(buffer)
    continuation = {:save_after_format, buffer, requested_version, :save}

    assert {:ok, committed_version} =
             Buffer.replace_content_if_version(buffer, requested_version, "FORMATTED\n", :lsp)

    Buffer.insert_text(buffer, "user ")

    new_state =
      BufferManagement.continue_after_format(state, continuation, {:committed, committed_version})

    assert File.read!(path) == "old\n"
    assert Buffer.dirty?(buffer)

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
             "Save skipped: buffer changed during formatting"
  end

  test "save_as continuation rejects edit after formatter commit" do
    target = tmp_path("external-format-save-as-race.txt")
    state = base_state("old\n")
    buffer = state.workspace.buffers.active
    requested_version = Buffer.version(buffer)
    continuation = {:save_after_format, buffer, requested_version, {:save_as, target}}

    assert {:ok, committed_version} =
             Buffer.replace_content_if_version(buffer, requested_version, "FORMATTED\n", :lsp)

    Buffer.insert_text(buffer, "user ")

    new_state =
      BufferManagement.continue_after_format(state, continuation, {:committed, committed_version})

    refute File.exists?(target)
    assert Buffer.file_path(buffer) == nil
    assert Buffer.dirty?(buffer)

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
             "Save skipped: buffer changed during formatting"
  end

  test "dead buffer failed terminal does not exit the editor continuation" do
    path = tmp_path("external-format-dead-buffer.txt")
    File.write!(path, "old\n")
    state = base_state("old\n", file_path: path)
    buffer = state.workspace.buffers.active
    continuation = {:save_after_format, buffer, Buffer.version(buffer), :save}
    monitor = Process.monitor(buffer)
    Process.exit(buffer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^buffer, :killed}

    new_state = BufferManagement.continue_after_format(state, continuation, {:failed, :not_alive})

    assert File.read!(path) == "old\n"

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
             "Save failed: buffer closed"
  end

  test "external formatter failure continues only if the buffer is still at requested version" do
    path = tmp_path("external-format-failure.txt")
    File.write!(path, "hello\n")
    state = base_state("hello\n", file_path: path)
    buffer = state.workspace.buffers.active
    version = Buffer.version(buffer)
    continuation = {:save_after_format, buffer, version, :save}
    {state, request} = external_request(state, buffer, continuation)

    {new_state, _outcome} =
      ExternalFormat.apply(state, Outcome.failed(request, "formatter failed"))

    assert File.read!(path) == "hello\n"
    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) =~ "Wrote"

    stale_path = tmp_path("external-format-failure-stale.txt")
    File.write!(stale_path, "old\n")
    stale_state = base_state("old\n", file_path: stale_path)
    stale_buffer = stale_state.workspace.buffers.active
    stale_version = Buffer.version(stale_buffer)
    stale_continuation = {:save_after_format, stale_buffer, stale_version, :save}
    {stale_state, stale_request} = external_request(stale_state, stale_buffer, stale_continuation)
    Buffer.insert_text(stale_buffer, "new ")

    {stale_state, _outcome} =
      ExternalFormat.apply(stale_state, Outcome.failed(stale_request, "formatter failed"))

    assert File.read!(stale_path) == "old\n"

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(stale_state) ==
             "Save skipped: buffer changed during formatting"
  end

  test "successful replacement does not query a buffer that closes after replying" do
    buffer =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:replace_content_if_version, 0, "FORMATTED\n", :user}} ->
            GenServer.reply(from, {:ok, 1})
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
    assert match?({:completed, _result}, outcome.value)
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
    assert outcome.value == {:stale, :buffer_version_changed}
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
    assert match?({:completed, _result}, outcome.value)
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
    assert read_only_outcome.value == {:failed, :read_only}

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
    assert closed_outcome.value == {:failed, :buffer_closed}
  end

  test "failed, canceled, and stale outcomes have user-visible feedback" do
    state = base_state("hello\n")
    buffer = state.workspace.buffers.active
    {state, request} = external_request(state, buffer)

    {failed_state, failed} =
      ExternalFormat.apply(state, Outcome.failed(request, "formatter failed"))

    assert feedback(failed_state).message == "Format error: formatter failed"
    assert feedback(failed_state).status == :error
    assert match?({:failed, _reason}, failed.value)

    {timeout_state, timeout} = ExternalFormat.apply(state, Outcome.failed(request, :timeout))
    assert feedback(timeout_state).message == "Format timed out"
    assert feedback(timeout_state).status == :timeout
    assert match?({:failed, _reason}, timeout.value)

    {canceled_state, canceled} =
      ExternalFormat.apply(state, Outcome.canceled(request, :requested))

    assert feedback(canceled_state).message == "Format canceled"
    assert feedback(canceled_state).status == :canceled
    assert match?({:canceled, _reason}, canceled.value)

    {stale_state, stale} =
      ExternalFormat.apply(state, Outcome.stale(Outcome.completed(request, nil), :changed))

    assert feedback(stale_state).message == "Buffer changed, format skipped"
    assert feedback(stale_state).status == :stale
    assert match?({:stale, _reason}, stale.value)
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
    assert match?({:completed, _result}, outcome.value)
  end

  @spec feedback(EditorState.t()) :: MingaEditor.State.Operation.t()
  defp feedback(state), do: OperationFeedback.selected(state.feedback.operation_feedback)

  @spec external_request(EditorState.t(), pid(), term() | nil) :: {EditorState.t(), Request.t()}
  defp external_request(state, buffer, continuation \\ nil) do
    {operation_feedback, operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :external_format,
        "buffer:" <> inspect(buffer),
        "Formatting..."
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    {state, ExternalFormat.request(buffer, "cat", operation.id, continuation)}
  end

  defp tmp_path(name) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    on_exit(fn -> File.rm(path) end)
    path
  end

  @spec base_state(String.t(), keyword()) :: EditorState.t()
  defp base_state(content, opts \\ []) do
    buffer_opts = Keyword.merge([content: content], opts)
    buffer = start_supervised!({BufferProcess, buffer_opts}, id: {:buffer, make_ref()})

    workspace = %MingaEditor.Session.State{
      editing: VimState.new(),
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      }
    }

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: workspace
    }
  end
end

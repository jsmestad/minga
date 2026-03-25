defmodule Minga.Editor.Commands.GitRemoteTest do
  @moduledoc """
  Tests for async git remote operations (push/pull/fetch) and the
  `:git_pull` command wiring.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor
  alias Minga.Editor.Commands.Git, as: GitCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp build_state(overrides) do
    Map.merge(
      %EditorState{port_manager: nil, workspace: %Minga.Workspace.State{viewport: Viewport.new(80, 24)}},
      overrides
    )
  end

  defp start_editor(content \\ "") do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10
      )

    {editor, buffer}
  end

  defp get_state(editor), do: :sys.get_state(editor)

  # Build a git_remote_op tuple with a fake monitor ref for unit tests.
  # Integration tests that go through the Editor GenServer use real monitors.
  defp make_remote_op(msg_ref, context) do
    fake_monitor = make_ref()
    {msg_ref, fake_monitor, context}
  end

  # ── Command registration ────────────────────────────────────────────────

  describe "command registration" do
    test "git_pull is registered as a command" do
      commands = GitCommands.__commands__()
      names = Enum.map(commands, & &1.name)

      assert :git_pull in names
    end

    test "git_push is registered as a command" do
      commands = GitCommands.__commands__()
      names = Enum.map(commands, & &1.name)

      assert :git_push in names
    end

    test "git_fetch is registered as a command" do
      commands = GitCommands.__commands__()
      names = Enum.map(commands, & &1.name)

      assert :git_fetch in names
    end
  end

  # ── handle_remote_result/3 ─────────────────────────────────────────────

  describe "handle_remote_result/3" do
    test "sets success message and clears git_remote_op on matching ref" do
      ref = make_ref()
      op = make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})
      state = build_state(%{git_remote_op: op})

      result = GitCommands.handle_remote_result(state, ref, :ok)

      assert result.status_msg == "Pushed"
      assert result.git_remote_op == nil
    end

    test "sets error message on matching ref with error result" do
      ref = make_ref()
      op = make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})
      state = build_state(%{git_remote_op: op})

      result = GitCommands.handle_remote_result(state, ref, {:error, "rejected"})

      assert result.status_msg == "Push failed: rejected"
      assert result.git_remote_op == nil
    end

    test "ignores stale results with non-matching ref" do
      current_ref = make_ref()
      stale_ref = make_ref()
      op = make_remote_op(current_ref, {"/tmp/repo", "Pushed", "Push failed"})

      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.handle_remote_result(state, stale_ref, :ok)

      assert result.status_msg == "Pushing…"
      assert result.git_remote_op == op
    end

    test "ignores result when no operation is in flight" do
      ref = make_ref()
      state = build_state(%{git_remote_op: nil, status_msg: nil})

      result = GitCommands.handle_remote_result(state, ref, :ok)

      assert result.git_remote_op == nil
      assert result.status_msg == nil
    end
  end

  # ── handle_remote_task_down/2 ──────────────────────────────────────────

  describe "handle_remote_task_down/2" do
    test "clears git_remote_op when task monitor matches" do
      msg_ref = make_ref()
      task_monitor = make_ref()
      op = {msg_ref, task_monitor, {"/tmp/repo", "Pushed", "Push failed"}}
      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.handle_remote_task_down(state, task_monitor)

      assert result.git_remote_op == nil
      assert result.status_msg == "Git operation failed unexpectedly"
    end

    test "returns :not_matched when monitor ref doesn't match" do
      msg_ref = make_ref()
      task_monitor = make_ref()
      unrelated_monitor = make_ref()
      op = {msg_ref, task_monitor, {"/tmp/repo", "Pushed", "Push failed"}}
      state = build_state(%{git_remote_op: op})

      assert GitCommands.handle_remote_task_down(state, unrelated_monitor) == :not_matched
    end

    test "returns :not_matched when no operation is in flight" do
      state = build_state(%{git_remote_op: nil})

      assert GitCommands.handle_remote_task_down(state, make_ref()) == :not_matched
    end
  end

  # ── Async integration via Editor GenServer ─────────────────────────────

  describe "async git remote result via Editor" do
    test "Editor handles {:git_remote_result, ref, :ok} message" do
      {editor, _buffer} = start_editor()
      ref = make_ref()
      task_monitor = make_ref()

      :sys.replace_state(editor, fn state ->
        %{state | git_remote_op: {ref, task_monitor, {"/tmp/repo", "Fetched", "Fetch failed"}}}
      end)

      send(editor, {:git_remote_result, ref, :ok})
      state = get_state(editor)

      assert state.status_msg == "Fetched"
      assert state.git_remote_op == nil
    end

    test "Editor handles {:git_remote_result, ref, {:error, reason}} message" do
      {editor, _buffer} = start_editor()
      ref = make_ref()
      task_monitor = make_ref()

      :sys.replace_state(editor, fn state ->
        %{state | git_remote_op: {ref, task_monitor, {"/tmp/repo", "Pulled", "Pull failed"}}}
      end)

      send(editor, {:git_remote_result, ref, {:error, "merge conflict"}})
      state = get_state(editor)

      assert state.status_msg == "Pull failed: merge conflict"
      assert state.git_remote_op == nil
    end

    test "Editor clears git_remote_op when task crashes via :DOWN" do
      {editor, _buffer} = start_editor()
      ref = make_ref()
      task_monitor = make_ref()
      # Spawn a short-lived process just to get a real pid for the :DOWN message
      fake_pid = spawn(fn -> :ok end)

      :sys.replace_state(editor, fn state ->
        %{state | git_remote_op: {ref, task_monitor, {"/tmp/repo", "Pushed", "Push failed"}}}
      end)

      # Simulate the :DOWN the BEAM would send when the monitored task crashes
      send(editor, {:DOWN, task_monitor, :process, fake_pid, :killed})
      _ = :sys.get_state(editor)

      state = get_state(editor)
      assert state.git_remote_op == nil
      assert state.status_msg == "Git operation failed unexpectedly"
    end

    test "stale :DOWN after successful result is a no-op" do
      {editor, _buffer} = start_editor()
      ref = make_ref()
      task_monitor = make_ref()
      fake_pid = spawn(fn -> :ok end)

      :sys.replace_state(editor, fn state ->
        %{state | git_remote_op: {ref, task_monitor, {"/tmp/repo", "Fetched", "Fetch failed"}}}
      end)

      # Result arrives first and clears the op (with demonitor+flush in production)
      send(editor, {:git_remote_result, ref, :ok})
      _ = :sys.get_state(editor)

      assert get_state(editor).git_remote_op == nil
      assert get_state(editor).status_msg == "Fetched"

      # A stale :DOWN arrives after (in production, demonitor(:flush) prevents this,
      # but if it slips through, it should be harmless)
      send(editor, {:DOWN, task_monitor, :process, fake_pid, :normal})
      _ = :sys.get_state(editor)

      state = get_state(editor)
      # Op stays nil, status_msg unchanged (not overwritten with crash message)
      assert state.git_remote_op == nil
      assert state.status_msg == "Fetched"
    end
  end

  # ── Concurrent operation guard ─────────────────────────────────────────

  describe "concurrent operation guard" do
    test "rejects remote action when operation already in flight" do
      ref = make_ref()
      op = make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})

      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.execute(state, :git_pull)

      assert result.status_msg == "Git operation already in progress"
      assert result.git_remote_op == op
    end
  end
end

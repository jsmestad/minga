defmodule MingaEditor.Commands.GitRemoteTest do
  @moduledoc """
  Tests for async git remote operations (push/pull/fetch) and the
  `:git_pull` command wiring.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor
  alias MingaEditor.Commands.Git, as: GitCommands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp build_state(overrides) do
    {status_msg, overrides} = Map.pop(overrides, :status_msg)

    state =
      Map.merge(
        %EditorState{
          port_manager: nil,
          workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(80, 24)}
        },
        overrides
      )

    if status_msg, do: EditorState.set_status(state, status_msg), else: state
  end

  defp start_editor(content \\ "") do
    {:ok, buffer} = BufferProcess.start_link(content: content)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim
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

  defp start_stub_repo(dir, entries) do
    File.mkdir_p!(Path.join(dir, ".git"))
    Minga.Git.Stub.set_root(dir, dir)
    Minga.Git.Stub.set_status(dir, entries)
    {:ok, repo} = Minga.Git.Repo.ensure_started(dir, dir)

    on_exit(fn ->
      if Process.alive?(repo), do: GenServer.stop(repo)
      Minga.Git.Stub.clear(dir)
    end)

    repo
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

    test "git_pull_and_retry is registered as a command" do
      commands = GitCommands.__commands__()
      names = Enum.map(commands, & &1.name)

      assert :git_pull_and_retry in names
    end
  end

  # ── handle_remote_result/3 ─────────────────────────────────────────────

  describe "handle_remote_result/3" do
    test "sets success message and clears git_remote_op on matching ref" do
      ref = make_ref()
      op = make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})
      state = build_state(%{git_remote_op: op})

      result = GitCommands.handle_remote_result(state, ref, :ok)

      assert result.shell_state.status_msg == "Pushed"
      assert result.git_remote_op == nil
    end

    test "sets error message on matching ref with error result" do
      ref = make_ref()
      op = make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})
      state = build_state(%{git_remote_op: op})

      result = GitCommands.handle_remote_result(state, ref, {:error, "rejected"})

      assert result.shell_state.status_msg == "Push failed: rejected"
      assert result.git_remote_op == nil
    end

    test "suggests pull and retry only for non-fast-forward push errors" do
      reasons = [
        "non-fast-forward rejected",
        "fetch first",
        "remote contains work that you do not have locally",
        "tip of your current branch is behind its remote counterpart"
      ]

      for reason <- reasons do
        ref = make_ref()
        op = make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})
        state = build_state(%{git_remote_op: op})

        result = GitCommands.handle_remote_result(state, ref, {:error, reason})

        assert %{
                 message: message,
                 level: :error,
                 action: :pull_and_retry,
                 dismiss_ref: dismiss_ref
               } = result.shell_state.git_toast

        assert message == "Push failed: #{reason}"
        assert is_reference(dismiss_ref)
      end
    end

    test "does not suggest pull and retry for generic push rejections" do
      ref = make_ref()
      op = make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})
      state = build_state(%{git_remote_op: op})

      result =
        GitCommands.handle_remote_result(
          state,
          ref,
          {:error, "rejected by protected branch hook"}
        )

      assert %{action: nil} = result.shell_state.git_toast
    end

    test "does not suggest pull and retry for non-push errors" do
      ref = make_ref()
      op = make_remote_op(ref, {"/tmp/repo", "Pulled", "Pull failed"})
      state = build_state(%{git_remote_op: op})

      result = GitCommands.handle_remote_result(state, ref, {:error, "fetch first"})

      assert %{action: nil} = result.shell_state.git_toast
    end

    @tag :tmp_dir
    test "refreshes repo cache after error result", %{tmp_dir: dir} do
      initial = [%Minga.Git.StatusEntry{path: "before.ex", status: :modified, staged: false}]
      refreshed = [%Minga.Git.StatusEntry{path: "after.ex", status: :conflict, staged: false}]
      repo = start_stub_repo(dir, initial)
      ref = make_ref()
      state = build_state(%{git_remote_op: make_remote_op(ref, {dir, "Pulled", "Pull failed"})})

      Minga.Git.Stub.set_status(dir, refreshed)
      _result = GitCommands.handle_remote_result(state, ref, {:error, "merge conflict"})
      :sys.get_state(repo)

      assert Minga.Git.repo_status(repo) == refreshed
    end

    test "ignores stale results with non-matching ref" do
      current_ref = make_ref()
      stale_ref = make_ref()
      op = make_remote_op(current_ref, {"/tmp/repo", "Pushed", "Push failed"})

      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.handle_remote_result(state, stale_ref, :ok)

      assert result.shell_state.status_msg == "Pushing…"
      assert result.git_remote_op == op
    end

    test "ignores result when no operation is in flight" do
      ref = make_ref()
      state = build_state(%{git_remote_op: nil})

      result = GitCommands.handle_remote_result(state, ref, :ok)

      assert result.git_remote_op == nil
      assert result.shell_state.status_msg == nil
    end

    test "toast dismissal only clears the matching toast" do
      old_ref = make_ref()
      new_ref = make_ref()

      state =
        build_state(%{})
        |> EditorState.set_git_toast(%{
          message: "Newer toast",
          level: :success,
          action: nil,
          dismiss_ref: new_ref
        })

      assert EditorState.clear_git_toast(state, old_ref).shell_state.git_toast.message ==
               "Newer toast"

      assert EditorState.clear_git_toast(state, new_ref).shell_state.git_toast == nil
    end
  end

  # ── handle_remote_task_down/3 ──────────────────────────────────────────

  describe "handle_remote_task_down/3" do
    test "clears git_remote_op when task monitor matches" do
      msg_ref = make_ref()
      task_monitor = make_ref()
      op = {msg_ref, task_monitor, {"/tmp/repo", "Pushed", "Push failed"}}
      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.handle_remote_task_down(state, task_monitor, :killed)

      assert result.git_remote_op == nil
      assert result.shell_state.status_msg == "Git operation failed unexpectedly: killed"

      assert %{message: "Git operation failed unexpectedly: killed", level: :error, action: nil} =
               result.shell_state.git_toast
    end

    @tag :tmp_dir
    test "refreshes repo cache after task crash", %{tmp_dir: dir} do
      initial = [%Minga.Git.StatusEntry{path: "before.ex", status: :modified, staged: false}]
      refreshed = [%Minga.Git.StatusEntry{path: "after.ex", status: :conflict, staged: false}]
      repo = start_stub_repo(dir, initial)
      task_monitor = make_ref()

      state =
        build_state(%{git_remote_op: {make_ref(), task_monitor, {dir, "Pulled", "Pull failed"}}})

      Minga.Git.Stub.set_status(dir, refreshed)
      _result = GitCommands.handle_remote_task_down(state, task_monitor, :killed)
      :sys.get_state(repo)

      assert Minga.Git.repo_status(repo) == refreshed
    end

    test "normal task exit leaves operation in flight for the result message" do
      msg_ref = make_ref()
      task_monitor = make_ref()
      op = {msg_ref, task_monitor, {"/tmp/repo", "Pushed", "Push failed"}}
      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.handle_remote_task_down(state, task_monitor, :normal)

      assert result.git_remote_op == op
      assert result.shell_state.status_msg == "Pushing…"
      assert result.shell_state.git_toast == nil
    end

    test "returns :not_matched when monitor ref doesn't match" do
      msg_ref = make_ref()
      task_monitor = make_ref()
      unrelated_monitor = make_ref()
      op = {msg_ref, task_monitor, {"/tmp/repo", "Pushed", "Push failed"}}
      state = build_state(%{git_remote_op: op})

      assert GitCommands.handle_remote_task_down(state, unrelated_monitor, :killed) ==
               :not_matched
    end

    test "returns :not_matched when no operation is in flight" do
      state = build_state(%{git_remote_op: nil})

      assert GitCommands.handle_remote_task_down(state, make_ref(), :killed) == :not_matched
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

      assert state.shell_state.status_msg == "Fetched"
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

      assert state.shell_state.status_msg == "Pull failed: merge conflict"
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
      assert state.shell_state.status_msg == "Git operation failed unexpectedly: killed"
      assert %{level: :error, action: nil} = state.shell_state.git_toast
    end

    test "normal :DOWN before result does not fail the operation" do
      {editor, _buffer} = start_editor()
      ref = make_ref()
      task_monitor = make_ref()
      fake_pid = spawn(fn -> :ok end)

      :sys.replace_state(editor, fn state ->
        %{state | git_remote_op: {ref, task_monitor, {"/tmp/repo", "Fetched", "Fetch failed"}}}
      end)

      send(editor, {:DOWN, task_monitor, :process, fake_pid, :normal})
      state_after_down = get_state(editor)

      assert state_after_down.git_remote_op ==
               {ref, task_monitor, {"/tmp/repo", "Fetched", "Fetch failed"}}

      assert state_after_down.shell_state.status_msg == nil

      send(editor, {:git_remote_result, ref, :ok})
      _ = :sys.get_state(editor)

      state = get_state(editor)
      assert state.git_remote_op == nil
      assert state.shell_state.status_msg == "Fetched"
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
      assert get_state(editor).shell_state.status_msg == "Fetched"

      # A stale :DOWN arrives after (in production, demonitor(:flush) prevents this,
      # but if it slips through, it should be harmless)
      send(editor, {:DOWN, task_monitor, :process, fake_pid, :normal})
      _ = :sys.get_state(editor)

      state = get_state(editor)
      # Op stays nil, status_msg unchanged (not overwritten with crash message)
      assert state.git_remote_op == nil
      assert state.shell_state.status_msg == "Fetched"
    end
  end

  # ── Concurrent operation guard ─────────────────────────────────────────

  describe "concurrent operation guard" do
    test "rejects remote action when operation already in flight" do
      ref = make_ref()
      op = make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})

      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.execute(state, :git_pull)

      assert result.shell_state.status_msg == "Git operation already in progress"
      assert result.git_remote_op == op
    end
  end
end

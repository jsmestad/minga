defmodule MingaEditor.Commands.GitRemoteTest do
  @moduledoc """
  Focused tests for async git remote operation feedback.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor
  alias MingaEditor.Commands.Git, as: GitCommands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  describe "command registration" do
    test "remote git commands are registered" do
      names = GitCommands.__commands__() |> Enum.map(& &1.name)

      assert :git_pull in names
      assert :git_push in names
      assert :git_fetch in names
      assert :git_pull_and_retry in names
    end
  end

  describe "handle_remote_result/3" do
    test "matching success clears the in-flight operation and reports success" do
      ref = make_ref()

      state =
        build_state(%{git_remote_op: make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})})

      result = GitCommands.handle_remote_result(state, ref, :ok)

      assert result.shell_state.status_msg == "Pushed"
      assert result.git_remote_op == nil
    end

    test "non-fast-forward push failures offer pull-and-retry" do
      ref = make_ref()

      state =
        build_state(%{git_remote_op: make_remote_op(ref, {"/tmp/repo", "Pushed", "Push failed"})})

      result = GitCommands.handle_remote_result(state, ref, {:error, "non-fast-forward rejected"})

      assert result.git_remote_op == nil

      assert %{
               message: "Push failed: non-fast-forward rejected",
               level: :error,
               action: :pull_and_retry
             } = result.shell_state.git_toast
    end

    test "stale results leave the current operation untouched" do
      current_ref = make_ref()
      op = make_remote_op(current_ref, {"/tmp/repo", "Pushed", "Push failed"})
      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.handle_remote_result(state, make_ref(), :ok)

      assert result.shell_state.status_msg == "Pushing…"
      assert result.git_remote_op == op
    end
  end

  describe "handle_remote_task_down/3" do
    test "crashed tasks clear the operation and show an error toast" do
      task_monitor = make_ref()

      state =
        build_state(%{
          git_remote_op: {make_ref(), task_monitor, {"/tmp/repo", "Pushed", "Push failed"}}
        })

      result = GitCommands.handle_remote_task_down(state, task_monitor, :killed)

      assert result.git_remote_op == nil
      assert result.shell_state.status_msg == "Git operation failed unexpectedly: killed"

      assert %{message: "Git operation failed unexpectedly: killed", level: :error, action: nil} =
               result.shell_state.git_toast
    end

    test "normal task exit waits for the result message" do
      task_monitor = make_ref()
      op = {make_ref(), task_monitor, {"/tmp/repo", "Pushed", "Push failed"}}
      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.handle_remote_task_down(state, task_monitor, :normal)

      assert result.git_remote_op == op
      assert result.shell_state.status_msg == "Pushing…"
      assert result.shell_state.git_toast == nil
    end
  end

  describe "Editor GenServer routing" do
    test "git_remote_result messages are applied" do
      {editor, _buffer} = start_editor()
      ref = make_ref()
      put_remote_op(editor, {ref, make_ref(), {"/tmp/repo", "Fetched", "Fetch failed"}})

      send(editor, {:git_remote_result, ref, :ok})
      state = get_state(editor)

      assert state.shell_state.status_msg == "Fetched"
      assert state.git_remote_op == nil
    end

    test "task crash DOWN messages are applied" do
      {editor, _buffer} = start_editor()
      task_monitor = make_ref()
      fake_pid = spawn(fn -> :ok end)
      put_remote_op(editor, {make_ref(), task_monitor, {"/tmp/repo", "Pushed", "Push failed"}})

      send(editor, {:DOWN, task_monitor, :process, fake_pid, :killed})
      state = get_state(editor)

      assert state.git_remote_op == nil
      assert state.shell_state.status_msg == "Git operation failed unexpectedly: killed"
      assert %{level: :error, action: nil} = state.shell_state.git_toast
    end
  end

  describe "concurrent operation guard" do
    test "rejects remote actions when an operation is already in flight" do
      op = make_remote_op(make_ref(), {"/tmp/repo", "Pushed", "Push failed"})
      state = build_state(%{git_remote_op: op, status_msg: "Pushing…"})

      result = GitCommands.execute(state, :git_pull)

      assert result.shell_state.status_msg == "Git operation already in progress"
      assert result.git_remote_op == op
    end
  end

  defp build_state(overrides) do
    {status_msg, overrides} = Map.pop(overrides, :status_msg)

    state =
      Map.merge(
        %EditorState{
          port_manager: nil,
          workspace: %MingaEditor.Session.State{viewport: Viewport.new(80, 24)}
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

  defp put_remote_op(editor, op) do
    :sys.replace_state(editor, fn state -> %{state | git_remote_op: op} end)
  end

  defp make_remote_op(msg_ref, context) do
    {msg_ref, make_ref(), context}
  end
end

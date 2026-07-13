defmodule MingaEditor.Shell.Traditional.GitToastWorkflow do
  @moduledoc "Effectful timer workflow for the protocol-independent Git toast owner."

  alias MingaEditor.Shell.Traditional.GitToast
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState

  @dismiss_ms 3_000

  @doc "Publishes one latest-wins Git toast. Only info and success are timed."
  @spec publish(EditorState.t(), String.t(), GitToast.level(), GitToast.action()) ::
          EditorState.t()
  def publish(state, message, level, action \\ nil) do
    cancel_timer(state.shell_runtime.state.git_toast.timer)

    state =
      EditorState.update_shell_state(
        state,
        &ShellState.publish_git_toast(&1, message, level, action)
      )

    toast = state.shell_runtime.state.git_toast
    if GitToast.auto_dismiss?(toast), do: schedule(state, toast.id), else: state
  end

  @doc "Dismisses the current toast manually."
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(state) do
    cancel_timer(state.shell_runtime.state.git_toast.timer)
    EditorState.update_shell_state(state, &ShellState.dismiss_git_toast/1)
  end

  @doc "Dismisses only the expected current toast identity."
  @spec dismiss(EditorState.t(), GitToast.id()) :: EditorState.t()
  def dismiss(state, id) do
    toast = state.shell_runtime.state.git_toast
    if toast.id == id, do: cancel_timer(toast.timer)
    EditorState.update_shell_state(state, &ShellState.dismiss_git_toast(&1, id))
  end

  @doc "Handles a tagged auto-dismiss timeout; stale and sticky delivery are no-ops."
  @spec timeout(EditorState.t(), GitToast.id()) :: EditorState.t()
  def timeout(%{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state, id),
    do: EditorState.update_shell_state(state, &ShellState.timeout_git_toast(&1, id))

  def timeout(state, _id), do: state

  @spec schedule(EditorState.t(), GitToast.id()) :: EditorState.t()
  defp schedule(%{backend: :headless} = state, _id), do: state

  defp schedule(state, id) do
    timer = Process.send_after(self(), {:git_toast_timeout, id}, @dismiss_ms)
    EditorState.update_shell_state(state, &ShellState.record_git_toast_timer(&1, id, timer))
  end

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end
end

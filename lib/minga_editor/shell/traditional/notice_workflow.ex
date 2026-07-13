defmodule MingaEditor.Shell.Traditional.NoticeWorkflow do
  @moduledoc """
  Effectful Editor workflow for ordinary traditional-shell notices.

  Publishing while structured operation feedback owns the lane logs the
  message and leaves no notice queued for replay. Otherwise the latest notice
  receives an identity-safe two-second timeout outside headless mode.
  """

  alias Minga.Events
  alias MingaEditor.MessageLog
  alias MingaEditor.Shell.Traditional.Notice
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationFeedback

  @timeout_ms 2_000

  @doc "Publishes an ordinary notice under the status-lane arbitration contract."
  @spec publish(EditorState.t() | map(), String.t()) :: EditorState.t() | map()
  def publish(%{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state, message)
      when is_binary(message) do
    state = cancel_current_timer(state)

    case OperationFeedback.selected_from(state) do
      %Operation{status: status} when status in [:pending, :queued, :running] ->
        log_hidden(state, message)

      _terminal_or_absent ->
        publish_visible(state, message)
    end
  end

  def publish(%EditorState{} = state, message) when is_binary(message) do
    MessageLog.append_to_store(state, message, :info)
  end

  def publish(state, message) when is_binary(message) do
    Minga.Log.info(:editor, message)
    state
  end

  @doc "Acknowledges a notice before keyboard dispatch."
  @spec acknowledge(EditorState.t() | map()) :: EditorState.t() | map()
  def acknowledge(%{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state) do
    state
    |> cancel_current_timer()
    |> EditorState.update_shell_state(&ShellState.acknowledge_notice/1)
  end

  def acknowledge(state), do: state

  @doc "Dismisses a notice explicitly, such as from Ctrl-G."
  @spec dismiss(EditorState.t() | map()) :: EditorState.t() | map()
  def dismiss(%{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state) do
    state
    |> cancel_current_timer()
    |> EditorState.update_shell_state(&ShellState.dismiss_notice/1)
  end

  def dismiss(state), do: state

  @doc "Handles one identity-tagged timeout; stale delivery is a no-op."
  @spec timeout(EditorState.t() | map(), Notice.id()) :: EditorState.t() | map()
  def timeout(%{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state, id) do
    EditorState.update_shell_state(state, &ShellState.timeout_notice(&1, id))
  end

  def timeout(state, _id), do: state

  @doc "Returns the currently visible ordinary notice message."
  @spec message(EditorState.t() | map()) :: String.t() | nil
  def message(%{
        shell_runtime: %{
          state: %{notice: %MingaEditor.Shell.Traditional.Notice{message: message}}
        }
      }), do: message

  def message(_state), do: nil

  @spec publish_visible(EditorState.t() | map(), String.t()) :: EditorState.t() | map()
  defp publish_visible(state, message) do
    state = EditorState.update_shell_state(state, &ShellState.publish_notice(&1, message))
    %Notice{id: id} = state.shell_runtime.state.notice

    if Map.get(state, :backend) == :headless do
      state
    else
      timer = Process.send_after(self(), {:notice_timeout, id}, @timeout_ms)
      EditorState.update_shell_state(state, &ShellState.record_notice_timer(&1, id, timer))
    end
  end

  @spec log_hidden(EditorState.t() | map(), String.t()) :: EditorState.t() | map()
  defp log_hidden(state, message) do
    state = EditorState.update_shell_state(state, &ShellState.dismiss_notice/1)

    Events.broadcast(
      :log_message,
      %Events.LogMessageEvent{text: message, level: :info},
      state.events_registry
    )

    state
  end

  @spec cancel_current_timer(EditorState.t() | map()) :: EditorState.t() | map()
  defp cancel_current_timer(
         %{
           shell_runtime: %{state: %{notice: %MingaEditor.Shell.Traditional.Notice{timer: timer}}}
         } = state
       ) do
    cancel_timer(timer)
    state
  end

  defp cancel_current_timer(state), do: state

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end
end

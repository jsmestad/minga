defmodule MingaEditor.Shell.Traditional.NoticeWorkflow do
  @moduledoc """
  Effectful Editor workflow for ordinary traditional-shell notices.

  Publishing while structured operation feedback owns the lane logs the
  message and leaves no notice queued for replay. Otherwise the latest notice
  receives an identity-safe two-second timeout outside headless mode.
  """

  alias Minga.Events
  alias MingaEditor.MessageLog
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Notice
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationFeedback

  @timeout_ms 2_000

  @doc "Publishes an ordinary notice under the status-lane arbitration contract."
  @spec publish(EditorState.t(), String.t()) :: EditorState.t()
  def publish(
        %EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state,
        message
      )
      when is_binary(message) do
    state = cancel_current_timer(state)

    case OperationFeedback.selected(state.feedback.operation_feedback) do
      %Operation{status: status} when status in [:pending, :queued, :running] ->
        log_hidden(state, message)

      _terminal_or_absent ->
        publish_visible(state, message)
    end
  end

  def publish(%EditorState{} = state, message) when is_binary(message) do
    MessageLog.append_to_store(state, message, :info)
  end

  @doc "Acknowledges a notice before keyboard dispatch."
  @spec acknowledge(EditorState.t()) :: EditorState.t()
  def acknowledge(%EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state) do
    state
    |> cancel_current_timer()
    |> update_shell_state(&ShellState.acknowledge_notice/1)
  end

  def acknowledge(%EditorState{} = state), do: state

  @doc "Dismisses a notice explicitly, such as from Ctrl-G."
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(%EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state) do
    state
    |> cancel_current_timer()
    |> update_shell_state(&ShellState.dismiss_notice/1)
  end

  def dismiss(%EditorState{} = state), do: state

  @doc "Handles one identity-tagged timeout; stale delivery is a no-op."
  @spec timeout(EditorState.t(), Notice.id()) :: EditorState.t()
  def timeout(%EditorState{shell_runtime: %Runtime{state: %ShellState{}}} = state, id) do
    update_shell_state(state, &ShellState.timeout_notice(&1, id))
  end

  def timeout(%EditorState{} = state, _id), do: state

  @doc "Returns the currently visible ordinary notice message."
  @spec message(EditorState.t()) :: String.t() | nil
  def message(%EditorState{
        shell_runtime: %Runtime{state: %ShellState{notice: %Notice{message: message}}}
      }),
      do: message

  def message(%EditorState{}), do: nil

  @spec publish_visible(EditorState.t(), String.t()) :: EditorState.t()
  defp publish_visible(state, message) do
    state = update_shell_state(state, &ShellState.publish_notice(&1, message))
    %Notice{id: id} = state.shell_runtime.state.notice

    if match?(%{frontend: %{backend: :headless}}, state) do
      state
    else
      timer = Process.send_after(self(), {:notice_timeout, id}, @timeout_ms)
      update_shell_state(state, &ShellState.record_notice_timer(&1, id, timer))
    end
  end

  @spec log_hidden(EditorState.t(), String.t()) :: EditorState.t()
  defp log_hidden(state, message) do
    state = update_shell_state(state, &ShellState.dismiss_notice/1)

    Events.broadcast(
      :log_message,
      %Events.LogMessageEvent{text: message, level: :info},
      state.extension_surfaces.events_registry
    )

    state
  end

  @spec cancel_current_timer(EditorState.t()) :: EditorState.t()
  defp cancel_current_timer(
         %EditorState{shell_runtime: %Runtime{state: %ShellState{notice: %Notice{timer: timer}}}} =
           state
       ) do
    cancel_timer(timer)
    state
  end

  defp cancel_current_timer(%EditorState{} = state), do: state

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  @spec update_shell_state(EditorState.t(), (MingaEditor.Shell.Traditional.State.t() ->
                                               MingaEditor.Shell.Traditional.State.t())) ::
          EditorState.t()
  defp update_shell_state(%EditorState{} = state, transition) when is_function(transition, 1) do
    shell_state = state.shell_runtime |> Runtime.state() |> transition.()
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end
end

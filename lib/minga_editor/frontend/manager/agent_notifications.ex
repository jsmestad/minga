defmodule MingaEditor.Frontend.Manager.AgentNotifications do
  @moduledoc """
  Best-effort admission of "a task needs you" alerts and reliable withdrawal of admitted ones.

  The editor decides when to alert (`MingaEditor.Agent.TaskWorkflow`) and `MingaAgent.Notifier` publishes the alert with its task's session as the owner. Each session has at most one admitted alert. It is withdrawn when the editor says so, or when the session stops, through the owner monitor. macOS posts and removes a notification; the terminal frontend rings its bell and ignores withdrawals.

  Alerts must not occupy the renderer's required control queue or turn slow rendering into a terminal transport failure.
  """

  alias MingaEditor.Frontend.Manager.OutputHandler
  alias MingaEditor.Frontend.Manager.State
  alias MingaEditor.Frontend.Protocol

  defstruct admitted: %{}, withdrawals: MapSet.new()

  @typep id :: <<_::128>>
  @typep kind :: :needs_you | :withdrawn
  @type t :: %__MODULE__{
          admitted: %{pid() => {id(), reference()}},
          withdrawals: MapSet.t(id())
        }

  @retry_withdrawal_ms 100

  @doc "Posts an alert, replacing an owner's alert with another identity, or withdraws the alert with that identity admitted on this connection."
  @spec send_notification(State.t(), %{kind: kind(), id: id(), owner: pid()}) :: State.t()
  def send_notification(%{ready: false} = state, _event), do: state

  def send_notification(state, %{kind: :withdrawn, id: id, owner: owner}) do
    case Map.get(state.agent_notifications.admitted, owner) do
      {^id, ref} -> owner_down(state, owner, ref)
      _ -> state
    end
  end

  def send_notification(state, %{kind: :needs_you, id: id, owner: owner} = event) do
    case Map.get(state.agent_notifications.admitted, owner) do
      {^id, _ref} ->
        state

      # The editor lost the old identity (it restarted, or detached and reattached the session): the new alert replaces it.
      {_old, ref} ->
        state |> owner_down(owner, ref) |> send_notification(event)

      nil ->
        admit(state, id, owner)
    end
  end

  @spec admit(State.t(), id(), pid()) :: State.t()
  defp admit(state, id, owner) do
    case write(state, :needs_you, id) do
      {:accepted, state} ->
        output = state.agent_notifications
        admitted = Map.put(output.admitted, owner, {id, Process.monitor(owner)})
        %{state | agent_notifications: %{output | admitted: admitted}}

      {_result, state} ->
        state
    end
  end

  @doc "Withdraws the alert owned by the matching session monitor."
  @spec owner_down(State.t(), pid(), reference()) :: State.t()
  def owner_down(state, owner, ref) do
    output = state.agent_notifications

    case Map.get(output.admitted, owner) do
      {id, ^ref} ->
        Process.demonitor(ref, [:flush])
        output = %{output | admitted: Map.delete(output.admitted, owner)}
        withdraw(%{state | agent_notifications: output}, id)

      _ ->
        state
    end
  end

  @doc "Retires all alert monitors on transport disconnect."
  @spec disconnect(State.t()) :: State.t()
  def disconnect(state) do
    Enum.each(state.agent_notifications.admitted, fn {_owner, {_id, ref}} ->
      Process.demonitor(ref, [:flush])
    end)

    %{state | agent_notifications: %__MODULE__{}}
  end

  @doc "Retries only missing withdrawals, independently of required render output."
  @spec retry_withdrawals(State.t()) :: State.t()
  def retry_withdrawals(%{ready: false} = state), do: disconnect(state)

  def retry_withdrawals(state) do
    state = Enum.reduce_while(state.agent_notifications.withdrawals, state, &retry_withdrawal/2)
    if MapSet.size(state.agent_notifications.withdrawals) > 0, do: schedule_retry()
    state
  end

  @spec withdraw(State.t(), id()) :: State.t()
  defp withdraw(state, id) do
    case write(state, :withdrawn, id) do
      {:unwritable, state} ->
        output = state.agent_notifications
        if MapSet.size(output.withdrawals) == 0, do: schedule_retry()
        output = %{output | withdrawals: MapSet.put(output.withdrawals, id)}
        %{state | agent_notifications: output}

      {_result, state} ->
        state
    end
  end

  @spec retry_withdrawal(id(), State.t()) :: {:cont | :halt, State.t()}
  defp retry_withdrawal(id, state) do
    case write(state, :withdrawn, id) do
      {:accepted, state} ->
        output = state.agent_notifications
        output = %{output | withdrawals: MapSet.delete(output.withdrawals, id)}
        {:cont, %{state | agent_notifications: output}}

      {:unwritable, state} ->
        {:halt, state}

      {:disconnected, state} ->
        {:halt, disconnect(state)}
    end
  end

  @spec schedule_retry() :: reference()
  defp schedule_retry do
    Process.send_after(self(), :retry_agent_notification_withdrawals, @retry_withdrawal_ms)
  end

  @spec write(State.t(), kind(), id()) ::
          {MingaEditor.Frontend.Manager.lifecycle_admission(), State.t()}
  defp write(state, kind, id) do
    OutputHandler.admit_lifecycle_command(
      state,
      Protocol.encode_agent_desktop_notification(kind, id)
    )
  end
end

defmodule MingaEditor.Frontend.Manager.AgentNotifications do
  @moduledoc """
  Best-effort desktop alert admission and reliable retirement of admitted approvals.

  Alerts must not occupy the renderer's required control queue or turn slow rendering into a terminal transport failure.
  """

  alias MingaEditor.Frontend.Manager.OutputHandler
  alias MingaEditor.Frontend.Manager.State
  alias MingaEditor.Frontend.Protocol

  defstruct admitted_approvals: %{}, withdrawals: MapSet.new()

  @typep id :: <<_::128>>
  @typep kind :: :approval | :approval_cleared | :complete | :error
  @type t :: %__MODULE__{
          admitted_approvals: %{pid() => {id(), reference()}},
          withdrawals: MapSet.t(id())
        }

  @retry_withdrawal_ms 100

  @doc "Posts an alert once, or retires an approval previously admitted on this connection."
  @spec send_notification(State.t(), %{
          kind: kind(),
          id: id(),
          owner: pid(),
          debounce_ms: non_neg_integer()
        }) :: State.t()
  def send_notification(%{ready: false} = state, _event), do: state

  def send_notification(state, %{kind: :approval_cleared, id: id, owner: owner}) do
    case Map.get(state.agent_notifications.admitted_approvals, owner) do
      {^id, ref} -> owner_down(state, owner, ref)
      _ -> state
    end
  end

  def send_notification(state, %{kind: :approval, id: id, owner: owner}) do
    output = state.agent_notifications

    if Map.has_key?(output.admitted_approvals, owner) do
      state
    else
      case write(state, :approval, id, 0) do
        {:accepted, state} ->
          admitted_approvals =
            Map.put(output.admitted_approvals, owner, {id, Process.monitor(owner)})

          %{state | agent_notifications: %{output | admitted_approvals: admitted_approvals}}

        {_result, state} ->
          state
      end
    end
  end

  def send_notification(state, %{kind: kind, id: id, debounce_ms: debounce_ms}) do
    {_result, state} = write(state, kind, id, debounce_ms)
    state
  end

  @doc "Withdraws the approval owned by the matching session monitor."
  @spec owner_down(State.t(), pid(), reference()) :: State.t()
  def owner_down(state, owner, ref) do
    output = state.agent_notifications

    case Map.get(output.admitted_approvals, owner) do
      {id, ^ref} ->
        Process.demonitor(ref, [:flush])
        output = %{output | admitted_approvals: Map.delete(output.admitted_approvals, owner)}
        withdraw(%{state | agent_notifications: output}, id)

      _ ->
        state
    end
  end

  @doc "Retires all approval monitors on transport disconnect."
  @spec disconnect(State.t()) :: State.t()
  def disconnect(state) do
    Enum.each(state.agent_notifications.admitted_approvals, fn {_owner, {_id, ref}} ->
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
    case write(state, :approval_cleared, id, 0) do
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
    case write(state, :approval_cleared, id, 0) do
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
    Process.send_after(self(), :retry_agent_approval_withdrawals, @retry_withdrawal_ms)
  end

  @spec write(State.t(), kind(), id(), non_neg_integer()) ::
          {MingaEditor.Frontend.Manager.lifecycle_admission(), State.t()}
  defp write(state, kind, id, debounce_ms) do
    OutputHandler.admit_lifecycle_command(
      state,
      Protocol.encode_agent_desktop_notification(kind, id, debounce_ms)
    )
  end
end

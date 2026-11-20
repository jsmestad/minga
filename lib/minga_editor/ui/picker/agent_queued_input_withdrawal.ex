defmodule MingaEditor.UI.Picker.AgentQueuedInputWithdrawal do
  @moduledoc "Withdraws a confirmed queued revision without blocking or editing the composer."
  @behaviour MingaEditor.Effect

  alias MingaEditor.Effect.{Outcome, Policy, Request}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.UI.Picker.AgentQueuedInputSource

  @enforce_keys [:origin, :withdraw]
  defstruct [:origin, :withdraw]

  @typep withdrawal :: (-> :ok | {:error, term()})
  @type t :: %__MODULE__{origin: AgentQueuedInputSource.origin(), withdraw: withdrawal()}

  @doc "Schedules one confirmed withdrawal against the exact Session and queue entry."
  @spec start(State.t(), AgentQueuedInputSource.origin(), withdrawal()) :: State.t()
  def start(%State{effect_scheduler: nil} = state, _origin, _withdraw),
    do: report(state, "Queue withdrawal could not start.")

  def start(%State{effect_scheduler: scheduler} = state, origin, withdraw) do
    effect = %__MODULE__{origin: origin, withdraw: withdraw}
    request = Request.new(effect, {:queued_input, origin}, Policy.fifo(0), timeout_ms: 35_000)

    case EffectScheduler.schedule(scheduler, request) do
      {:ok, _id, _disposition} -> report(state, "Withdrawing queued input…")
      {:error, _reason} -> report(state, "Queue withdrawal could not start.")
    end
  catch
    :exit, _reason -> report(state, "Queue withdrawal could not start.")
  end

  @impl true
  @spec run(t()) :: {:ok, :withdrawn} | {:error, term()}
  def run(%__MODULE__{withdraw: withdraw}) do
    case withdraw.() do
      :ok -> {:ok, :withdrawn}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  @spec apply(State.t(), Outcome.t()) :: {State.t(), Outcome.t()}
  def apply(state, %Outcome{value: {status, result}, request: %{effect: effect}} = outcome)
      when status in [:completed, :failed] do
    case AgentQueuedInputSource.current_origin(state) do
      origin when origin == effect.origin -> {report(state, message(status, result)), outcome}
      _changed -> {state, outcome}
    end
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _result}}) when status in [:completed, :failed], do: true
  def render?(%Outcome{}), do: false

  @spec message(:completed | :failed, term()) :: String.t()
  defp message(:completed, :withdrawn), do: "Queued input withdrawn."

  defp message(:failed, :already_consumed),
    do: "That input already left the queue. No other input changed."

  defp message(:failed, :stale_queue_revision),
    do: "That queued input changed. Reopen the queue to review it."

  defp message(_status, _reason),
    do: "Withdrawal not confirmed. Reopen the queue before retrying."

  @spec report(State.t(), String.t()) :: State.t()
  defp report(state, message), do: NoticeWorkflow.publish(state, message)
end

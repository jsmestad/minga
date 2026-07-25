defmodule Minga.Test.LatestWinsEffectProbe do
  @moduledoc "Effect probe without custom coalescing, used to verify default latest-wins request coalescing."

  @behaviour MingaEditor.Effect

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:test_pid, :label]
  defstruct [:test_pid, :label]

  @type t :: %__MODULE__{test_pid: pid(), label: term()}

  @spec request(pid(), term(), term(), Policy.t()) :: Request.t()
  def request(test_pid, label, resource, %Policy{} = policy) when is_pid(test_pid) do
    effect = %__MODULE__{test_pid: test_pid, label: label}
    operation_id = System.unique_integer([:positive, :monotonic])
    Request.new(effect, resource, policy, operation_id)
  end

  @impl true
  @spec run(t()) :: {:ok, term()} | {:error, term()}
  def run(%__MODULE__{} = effect) do
    send(effect.test_pid, {:latest_wins_effect_started, effect.label, self()})

    receive do
      {:release_latest_wins_effect, label} when label == effect.label -> {:ok, effect.label}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(%EditorState{} = state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: false
end

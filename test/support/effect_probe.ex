defmodule Minga.Test.EffectProbe do
  @moduledoc "Deterministic typed effect used to exercise the effect scheduler."

  @behaviour MingaEditor.Effect

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.State, as: EditorState

  @type action ::
          :wait | {:return, term()} | {:error, term()} | {:raise, String.t()} | {:exit, term()}

  @enforce_keys [:test_pid, :label, :payloads, :action]
  defstruct [:test_pid, :label, :payloads, :action]

  @type t :: %__MODULE__{
          test_pid: pid(),
          label: term(),
          payloads: [term()],
          action: action()
        }

  @doc "Builds a deterministic scheduler request with data-only work instructions."
  @spec request(pid(), term(), term(), Policy.t(), action()) :: Request.t()
  def request(test_pid, label, resource, policy, action \\ :wait) when is_pid(test_pid) do
    build_request(test_pid, label, resource, policy, action, [])
  end

  @doc "Builds a deterministic request attributed to a contribution source."
  @spec source_request(
          pid(),
          term(),
          term(),
          Policy.t(),
          Minga.Extension.ContributionCleanup.contribution_source(),
          action()
        ) :: Request.t()
  def source_request(test_pid, label, resource, policy, source, action \\ :wait)
      when is_pid(test_pid) do
    build_request(test_pid, label, resource, policy, action, source: source)
  end

  @impl true
  @spec run(t()) :: {:ok, term()} | {:error, term()}
  def run(%__MODULE__{} = effect) do
    send(effect.test_pid, {:effect_started, effect.label, self(), effect.payloads})
    perform(effect)
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{} = older, %__MODULE__{} = newer) do
    send(newer.test_pid, {:effect_coalesced, older.label, newer.label})
    %{newer | payloads: older.payloads ++ newer.payloads}
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(%EditorState{} = state, %Outcome{} = outcome) do
    send(outcome.request.effect.test_pid, {
      :effect_applied,
      outcome.request.effect.label,
      outcome.status
    })

    {state, outcome}
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: false

  @spec build_request(pid(), term(), term(), Policy.t(), action(), keyword()) :: Request.t()
  defp build_request(test_pid, label, resource, policy, action, opts) do
    effect = %__MODULE__{test_pid: test_pid, label: label, payloads: [label], action: action}
    operation_id = System.unique_integer([:positive, :monotonic])
    Request.new(effect, resource, policy, Keyword.put(opts, :operation_id, operation_id))
  end

  @spec perform(t()) :: {:ok, term()} | {:error, term()}
  defp perform(%__MODULE__{action: :wait} = effect) do
    receive do
      {:release_effect, label} when label == effect.label -> {:ok, effect.payloads}
    end
  end

  defp perform(%__MODULE__{action: {:return, result}}), do: {:ok, result}
  defp perform(%__MODULE__{action: {:error, reason}}), do: {:error, reason}
  defp perform(%__MODULE__{action: {:raise, message}}), do: raise(message)
  defp perform(%__MODULE__{action: {:exit, reason}}), do: exit(reason)
end

defmodule MingaEditor.UI.Picker.FetchEffect do
  @moduledoc """
  Typed asynchronous picker fetch owned by the Editor effect scheduler.

  The effect carries immutable callback input plus the picker revision that may
  accept its normalized candidates. Worker lifecycle and cancellation remain
  scheduler-owned.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Source

  @enforce_keys [:source, :callback_source, :context, :revision]
  defstruct [:source, :callback_source, :context, :revision]

  @type t :: %__MODULE__{
          source: module(),
          callback_source: ContributionCleanup.contribution_source() | nil,
          context: Context.t(),
          revision: reference()
        }

  @typedoc "Normalized data allowed to cross from the picker worker to the Editor."
  @type result ::
          {:ok, [MingaEditor.UI.Picker.item()], [Candidate.t()], Source.fetch_meta()}

  @doc "Builds a latest-wins picker fetch request."
  @spec request(
          module(),
          ContributionCleanup.contribution_source() | nil,
          Context.t(),
          reference()
        ) :: Request.t()
  def request(source, callback_source, %Context{} = context, revision)
      when is_atom(source) and is_reference(revision) do
    effect = %__MODULE__{
      source: source,
      callback_source: callback_source,
      context: context,
      revision: revision
    }

    build_request(effect, source, callback_source)
  end

  @spec build_request(t(), module(), ContributionCleanup.contribution_source() | nil) ::
          Request.t()
  defp build_request(effect, source, nil) do
    Request.new(effect, {:picker_fetch, source}, Policy.latest_wins())
  end

  defp build_request(effect, source, callback_source) do
    Request.new(effect, {:picker_fetch, source}, Policy.latest_wins(), source: callback_source)
  end

  @impl true
  @spec run(t()) :: {:ok, result()} | {:error, term()}
  def run(%__MODULE__{} = effect) do
    case Source.fetch(effect.source, effect.context, effect.callback_source) do
      {:ok, items, meta} -> {:ok, {:ok, items, Candidate.from_items(items), meta}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{value: {:completed, result}, request: %Request{effect: effect}} = outcome
      ) do
    apply_result(state, effect, result, outcome)
  end

  def apply(
        state,
        %Outcome{value: {:failed, reason}, request: %Request{effect: effect}} = outcome
      ) do
    apply_result(state, effect, {:error, failure_message(reason)}, outcome)
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _payload}})
      when status in [:completed, :failed, :stale],
      do: true

  def render?(%Outcome{}), do: false

  @spec apply_result(EditorState.t(), t(), tuple(), Outcome.t()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_result(state, effect, result, outcome) do
    case PickerUI.apply_fetch_result(state, effect.source, effect.revision, result) do
      {:ok, state} -> {state, outcome}
      :stale -> {state, Outcome.stale(outcome, :picker_closed_or_replaced)}
    end
  end

  @spec failure_message(term()) :: String.t()
  defp failure_message({:source_admission_denied, source}),
    do: "Picker source unavailable: #{inspect(source)}"

  defp failure_message({:picker_source_exception, message}), do: message
  defp failure_message({:picker_source_exit, reason}), do: "Source timed out: #{inspect(reason)}"
  defp failure_message({:picker_source_throw, value}), do: "Source failed: #{inspect(value)}"
  defp failure_message(reason) when is_binary(reason), do: reason
  defp failure_message(reason), do: "Picker fetch failed: #{inspect(reason)}"
end

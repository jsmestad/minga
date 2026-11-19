defmodule MingaEditor.UI.Picker.AgentRetainedOutputCopy do
  @moduledoc "Writes an explicitly selected retained page and keeps it available if the clipboard fails."
  @behaviour MingaEditor.Effect

  alias MingaEditor.Effect.{Outcome, Policy, Request}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.UI.Picker.AgentRetainedOutputSource

  @enforce_keys [:bytes, :revision]
  defstruct [:bytes, :revision]

  @type t :: %__MODULE__{bytes: String.t(), revision: reference()}

  @doc "Starts a copy without closing the retained page or moving its selection."
  @spec start(State.t(), String.t(), reference()) :: State.t()
  def start(%State{effect_scheduler: nil} = state, _bytes, revision),
    do: failed(state, revision)

  def start(%State{effect_scheduler: scheduler} = state, bytes, revision) do
    effect = %__MODULE__{bytes: bytes, revision: revision}
    request = Request.new(effect, :system_clipboard, Policy.fifo(0), timeout_ms: 6_000)

    case EffectScheduler.schedule(scheduler, request) do
      {:ok, _id, _disposition} -> state
      {:error, _reason} -> failed(state, revision)
    end
  catch
    :exit, _reason -> failed(state, revision)
  end

  @impl true
  @spec run(t()) :: {:ok, :copied} | {:error, term()}
  def run(%__MODULE__{bytes: bytes}) do
    case Minga.Clipboard.write(bytes) do
      :ok -> {:ok, :copied}
      :unavailable -> {:error, :clipboard_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  @spec apply(State.t(), Outcome.t()) :: {State.t(), Outcome.t()}
  def apply(state, %Outcome{value: {:completed, :copied}, request: %{effect: effect}} = outcome) do
    {copied(state, effect.revision), outcome}
  end

  def apply(state, %Outcome{value: {:failed, _reason}, request: %{effect: effect}} = outcome),
    do: {failed(state, effect.revision), outcome}

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _result}}) when status in [:completed, :failed], do: true
  def render?(%Outcome{}), do: false

  @spec copied(State.t(), reference()) :: State.t()
  defp copied(
         %State{
           shell_runtime: %{state: %{modal: {:picker, %{picker_ui: picker}}}}
         } = state,
         revision
       )
       when picker.source == AgentRetainedOutputSource and picker.fetch_revision == revision do
    state |> PickerUI.close() |> NoticeWorkflow.publish("Copied retained tool output.")
  end

  defp copied(state, _revision), do: state

  @spec failed(State.t(), reference()) :: State.t()
  defp failed(state, revision) do
    result = {:error, "Copy not confirmed. Retry."}

    case PickerUI.apply_fetch_result(state, AgentRetainedOutputSource, revision, result) do
      {:ok, state} -> state
      :stale -> state
    end
  end
end

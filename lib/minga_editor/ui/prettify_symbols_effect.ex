defmodule MingaEditor.UI.PrettifySymbolsEffect do
  @moduledoc """
  Typed latest-wins prettification for one Buffer process.

  Buffer pid is the stable scheduler resource identity. Each request snapshots
  immutable highlight and filetype input before admission; a newer request for
  that buffer cancels the older worker/candidate instead of building a queue.
  The generation-owned scheduler starts workers under its `Task.Supervisor`.

  Scheduler supersession provides request correlation and cancellation. Workers
  return prepared decoration data without mutating the Buffer. The Editor applies
  only a scheduler-claimed outcome, so canceled and stale work cannot write.
  Worker or admission failures are logged and remain non-rendering; successful
  Buffer decoration notifications retain the existing render behavior.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Buffer
  alias Minga.Language
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.HighlightSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.PrettifySymbols

  @enforce_keys [:buffer, :highlight, :filetype]
  defstruct [:buffer, :highlight, :filetype]

  @type t :: %__MODULE__{
          buffer: pid(),
          highlight: Highlight.t(),
          filetype: atom()
        }

  @doc "Builds a latest-wins request with immutable highlight and filetype input."
  @spec request(pid(), Highlight.t(), atom()) :: Request.t()
  def request(buffer, %Highlight{} = highlight, filetype)
      when is_pid(buffer) and is_atom(filetype) do
    Request.new(
      %__MODULE__{buffer: buffer, highlight: highlight, filetype: filetype},
      {:prettify_symbols, buffer},
      Policy.latest_wins()
    )
  end

  @doc "Snapshots and schedules prettification, or synchronously clears disabled prettify conceals."
  @spec schedule(EditorState.t(), pid()) :: EditorState.t()
  def schedule(%EditorState{} = state, buffer) when is_pid(buffer) do
    if PrettifySymbols.enabled?() do
      highlight = HighlightSync.get_highlight(state, buffer)

      if highlight.capture_names != {} and tuple_size(highlight.spans) > 0 do
        filetype = buffer |> Buffer.file_path() |> Language.detect_filetype()
        schedule_request(state, request(buffer, highlight, filetype))
      else
        state
      end
    else
      clear_disabled(state, buffer)
    end
  end

  @impl true
  @spec run(t()) :: {:ok, PrettifySymbols.update()} | {:error, term()}
  def run(%__MODULE__{buffer: buffer, highlight: highlight, filetype: filetype}) do
    {:ok, PrettifySymbols.prepare(buffer, highlight, filetype)}
  catch
    :exit, {reason, {GenServer, :call, [^buffer | _args]}}
    when reason in [:noproc, :normal, :shutdown, :killed] ->
      {:error, {:buffer_exit, reason}}

    :exit, {{:shutdown, reason}, {GenServer, :call, [^buffer | _args]}} ->
      {:error, {:buffer_exit, {:shutdown, reason}}}
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{}, %__MODULE__{} = newer), do: newer

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        %EditorState{} = state,
        %Outcome{
          request: %Request{effect: %__MODULE__{buffer: buffer}},
          value: {:completed, update}
        } = outcome
      ) do
    :ok = PrettifySymbols.apply_update(buffer, update)
    {state, outcome}
  catch
    :exit, {reason, {GenServer, :call, [^buffer | _args]}}
    when reason in [:noproc, :normal, :shutdown, :killed] ->
      {state, Outcome.failed(outcome.request, {:buffer_exit, reason})}

    :exit, {{:shutdown, reason}, {GenServer, :call, [^buffer | _args]}} ->
      {state, Outcome.failed(outcome.request, {:buffer_exit, {:shutdown, reason}})}
  end

  def apply(%EditorState{} = state, %Outcome{value: {:failed, reason}} = outcome) do
    Minga.Log.warning(:editor, "Prettify symbols failed: #{inspect(reason)}")
    {state, outcome}
  end

  def apply(%EditorState{} = state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: false

  @spec clear_disabled(EditorState.t(), pid()) :: EditorState.t()
  defp clear_disabled(%EditorState{} = state, buffer) when is_pid(buffer) do
    _cancel_result =
      EffectScheduler.cancel_resource(state.effect_scheduler, {:prettify_symbols, buffer})

    :ok = PrettifySymbols.clear(buffer)
    state
  catch
    :exit, {reason, {GenServer, :call, [^buffer | _args]}}
    when reason in [:noproc, :normal, :shutdown, :killed] ->
      state

    :exit, {{:shutdown, _reason}, {GenServer, :call, [^buffer | _args]}} ->
      state
  end

  @spec schedule_request(EditorState.t(), Request.t()) :: EditorState.t()
  defp schedule_request(%EditorState{effect_scheduler: nil} = state, _request) do
    Minga.Log.warning(:editor, "Prettify symbols scheduler unavailable")
    state
  end

  defp schedule_request(state, request) do
    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} -> state
      {:error, reason} -> log_admission_failure(state, reason)
    end
  catch
    :exit, reason -> log_admission_failure(state, {:scheduler_unavailable, reason})
  end

  @spec log_admission_failure(EditorState.t(), term()) :: EditorState.t()
  defp log_admission_failure(state, reason) do
    Minga.Log.warning(:editor, "Prettify symbols not scheduled: #{inspect(reason)}")
    state
  end
end

defmodule MingaEditor.Session.CrashRecovery do
  @moduledoc """
  Reopens a file whose buffer crashed, with the unsaved text from its swap file.

  A buffer that stops for any reason other than a deliberate stop keeps its swap file and announces it with `:buffer_crashed`. The Editor takes that announcement when it retires the dead buffer and schedules this effect. Without it the kept text would be lost in the same session: the swap belongs to this running editor, so startup recovery skips it, and a buffer the user opens for the same file overwrites or deletes it.

  The swap is read under the scheduler's task supervisor, never in the Editor process. The read does not delete the file. The reopened buffer is dirty, so it owns the swap from then on: its next swap write replaces it, and a save or a normal close removes it. If the read or the reopen fails, the swap stays on disk and the next start recovers it.

  One crash schedules one recovery, so a buffer that keeps crashing cannot loop: each crash announces again, and each announcement is used once.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Events.BufferCrashedEvent
  alias Minga.Session.Swap
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Handlers.SessionRestore
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:path, :swap_path]
  defstruct [:path, :swap_path]

  @type t :: %__MODULE__{path: String.t(), swap_path: String.t()}

  @typedoc "The unsaved text read from the swap file of `path`."
  @type result :: {path :: String.t(), content :: String.t()}

  @doc """
  Schedules recovery for the crash a dead buffer announced.

  `nil` means the buffer stopped without announcing a crash, so nothing is scheduled. When the scheduler is unavailable or refuses the request, the swap stays on disk for the next start and a warning names it.
  """
  @spec schedule(EditorState.t(), BufferCrashedEvent.t() | nil) :: EditorState.t()
  def schedule(%EditorState{} = state, nil), do: state

  def schedule(%EditorState{effect_scheduler: nil} = state, %BufferCrashedEvent{} = crash),
    do: not_scheduled(state, crash, :scheduler_unavailable)

  def schedule(%EditorState{} = state, %BufferCrashedEvent{} = crash) do
    effect = %__MODULE__{path: crash.path, swap_path: crash.swap_path}
    request = Request.new(effect, {:crash_recovery, crash.path}, Policy.fifo(1))

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} -> state
      {:error, reason} -> not_scheduled(state, crash, reason)
    end
  catch
    :exit, reason -> not_scheduled(state, crash, {:scheduler_unavailable, reason})
  end

  @impl true
  @spec run(t()) :: {:ok, result()} | {:error, term()}
  def run(%__MODULE__{path: path, swap_path: swap_path}) do
    case Swap.read(swap_path) do
      {:ok, %{path: ^path}, content} -> {:ok, {path, content}}
      {:ok, %{path: other}, _content} -> {:error, {:swap_belongs_to, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(%EditorState{} = state, %Outcome{value: {:completed, {path, content}}} = outcome),
    do: {SessionRestore.recover_crashed_buffer(state, path, content), outcome}

  def apply(
        %EditorState{} = state,
        %Outcome{value: {:failed, reason}, request: %Request{effect: %__MODULE__{} = effect}} =
          outcome
      ) do
    Minga.Log.warning(
      :editor,
      "Could not read the unsaved text of #{effect.path} from #{effect.swap_path}: #{inspect(reason)}"
    )

    {state, outcome}
  end

  def apply(%EditorState{} = state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {:completed, _result}}), do: true
  def render?(%Outcome{}), do: false

  @spec not_scheduled(EditorState.t(), BufferCrashedEvent.t(), term()) :: EditorState.t()
  defp not_scheduled(state, %BufferCrashedEvent{} = crash, reason) do
    Minga.Log.warning(
      :editor,
      "Unsaved text of #{crash.path} stays in #{crash.swap_path} until Minga next starts: #{inspect(reason)}"
    )

    state
  end
end

defmodule MingaEditor.Session.CrashRecovery do
  @moduledoc """
  Reopens a file whose buffer crashed, with the unsaved text from its swap file.

  A buffer that stops for any reason other than a deliberate stop keeps its swap file and announces it with `:buffer_crashed`. The Editor takes that announcement when it retires the dead buffer and schedules this effect. Without it the kept text would be lost in the same session: the swap belongs to this running editor, so startup recovery skips it, and a buffer the user opens for the same file would replace or remove it.

  The swap is read under the scheduler's task supervisor, never in the Editor process. The read does not delete the file, so the text survives a failure of the reopen itself. If the read or the reopen fails, the swap stays on disk and the next start recovers it.

  Three rules keep recovery from doing harm:

  - **Newer text wins.** If a buffer for the file is open again by the time the swap has been read, that buffer is left alone and the swap is kept.
  - **One automatic reopen.** A buffer that recovery reopened and that crashes again is not reopened a second time. Its swap stays for the next start, so text that crashes its buffer cannot loop.
  - **Focus follows the crash.** The reopened buffer takes focus only when the crashed buffer had it. A background buffer comes back in the background.

  The reopened buffer is dirty. Once buffers the editor opens have a swap directory (#4257), it writes that swap again and removes it on save or close.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Buffer
  alias Minga.Events.BufferCrashedEvent
  alias Minga.Log
  alias Minga.Session.Swap
  alias MingaEditor.Commands
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.BufferLifecycle

  @enforce_keys [:path, :swap_path, :activate?]
  defstruct [:path, :swap_path, :activate?]

  @type t :: %__MODULE__{path: String.t(), swap_path: String.t(), activate?: boolean()}

  @typedoc "The unsaved text read from the swap file of `path`."
  @type result :: {path :: String.t(), content :: String.t()}

  @doc """
  Schedules recovery for the crash a dead buffer announced.

  `nil` means the buffer stopped without announcing a crash, so nothing is scheduled. A `:repeated` crash is not recovered again. `activate?` says whether the dead buffer had focus. When the scheduler is unavailable or refuses the request, the swap stays on disk for the next start and a warning names it.
  """
  @spec schedule(EditorState.t(), BufferLifecycle.crash() | nil, boolean()) :: EditorState.t()
  def schedule(%EditorState{} = state, nil, _activate?), do: state

  def schedule(%EditorState{} = state, {:repeated, %BufferCrashedEvent{} = crash}, _activate?) do
    Log.warning(
      :editor,
      "#{crash.path} crashed again after it was reopened. Its unsaved text stays in #{crash.swap_path} until Minga next starts."
    )

    NoticeWorkflow.publish(
      state,
      "#{Path.basename(crash.path)} crashed again; its unsaved text is kept for the next start"
    )
  end

  def schedule(
        %EditorState{effect_scheduler: nil} = state,
        {:first, %BufferCrashedEvent{} = crash},
        _activate?
      ),
      do: not_scheduled(state, crash, :scheduler_unavailable)

  def schedule(%EditorState{} = state, {:first, %BufferCrashedEvent{} = crash}, activate?)
      when is_boolean(activate?) do
    effect = %__MODULE__{path: crash.path, swap_path: crash.swap_path, activate?: activate?}
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
  def apply(
        %EditorState{} = state,
        %Outcome{
          value: {:completed, {path, content}},
          request: %Request{effect: %__MODULE__{} = effect}
        } = outcome
      ),
      do: {reopen(state, effect, path, content), outcome}

  def apply(
        %EditorState{} = state,
        %Outcome{value: {:failed, reason}, request: %Request{effect: %__MODULE__{} = effect}} =
          outcome
      ) do
    Log.warning(
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

  @spec reopen(EditorState.t(), t(), String.t(), String.t()) :: EditorState.t()
  defp reopen(state, %__MODULE__{} = effect, path, content) do
    case start_with_text(state, path, content) do
      {:ok, buffer} ->
        Log.info(:editor, "Recovered after a crash: #{Path.basename(path)}")

        state
        |> register(buffer, path, effect.activate?)
        |> EditorState.mark_buffer_crash_recovered(buffer)
        |> NoticeWorkflow.publish(
          "#{Path.basename(path)} was reopened with its unsaved text after its buffer crashed"
        )

      {:error, :already_open} ->
        Log.warning(
          :editor,
          "#{path} is open again, so its text from before the crash was not restored. It stays in #{effect.swap_path}."
        )

        state

      {:error, reason} ->
        Log.warning(
          :editor,
          "Could not reopen #{path} with its unsaved text. It stays in #{effect.swap_path}: #{inspect(reason, limit: 5)}"
        )

        state
    end
  end

  # Starts the buffer for the file and gives it the recovered text, which marks it dirty.
  # A buffer that is already open for the file holds newer text, so it is never overwritten.
  @spec start_with_text(EditorState.t(), String.t(), String.t()) ::
          {:ok, pid()} | {:error, term()}
  defp start_with_text(state, path, content) do
    case Buffer.pid_for_path(path) do
      {:ok, _open_buffer} ->
        {:error, :already_open}

      :not_found ->
        with {:ok, buffer} <-
               Commands.start_buffer(path, state.interaction.options_server,
                 events_registry: state.extension_surfaces.events_registry
               ),
             :ok <- Buffer.replace_content(buffer, content, :recovery) do
          {:ok, buffer}
        end
    end
  catch
    # The new buffer can stop between its start and the content call.
    # It is not monitored yet, so nothing else reports it.
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec register(EditorState.t(), pid(), String.t(), boolean()) :: EditorState.t()
  defp register(state, buffer, path, true),
    do: BufferRegistry.register_buffer(state, buffer, path)

  defp register(state, buffer, path, false),
    do: BufferRegistry.register_buffer_background(state, buffer, path)

  @spec not_scheduled(EditorState.t(), BufferCrashedEvent.t(), term()) :: EditorState.t()
  defp not_scheduled(state, %BufferCrashedEvent{} = crash, reason) do
    Log.warning(
      :editor,
      "Unsaved text of #{crash.path} stays in #{crash.swap_path} until Minga next starts: #{inspect(reason)}"
    )

    state
  end
end

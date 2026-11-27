defmodule MingaEditor.Session.CrashRecovery do
  @moduledoc """
  Reopens a file whose buffer crashed, with the unsaved text from its swap file.

  A buffer that stops for any reason other than a deliberate stop keeps its swap file and announces it with `:buffer_crashed`. The Editor takes that announcement when it retires the dead buffer and schedules this effect. Without it the kept text would be lost in the same session: the swap belongs to this running editor, so startup recovery skips it, and a buffer the user opens for the same file would replace or remove it.

  The swap is read under the scheduler's task supervisor, never in the Editor process. The read does not delete the file, so the text survives a failure of the reopen itself. If the read or the reopen fails, the swap stays on disk and the next start recovers it.

  Three rules keep recovery from doing harm:

  - **Newer text wins.** A buffer that is open again for the file took the kept swap when it started (`Minga.Buffer.Process` takes a kept swap at its own swap path), so it is the owner of that text. If the user has typed in it since, it keeps its newer text.
  - **One automatic reopen.** A buffer that recovery reopened and that crashes again is not reopened a second time. Its swap stays for the next start, so text that crashes its buffer cannot loop.
  - **Focus follows the crash.** The reopened buffer takes focus only when the crashed buffer had it. A background buffer comes back in the background.

  The reopened buffer is dirty and owns the swap file: it writes it again after edits and removes it on save or close.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Buffer
  alias Minga.Events.BufferCrashedEvent
  alias Minga.Log
  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery
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
  @type result :: {Swap.identity(), String.t()}

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
    case Recovery.read(swap_path) do
      {:ok, %{path: ^path} = source, content} -> {:ok, {source, content}}
      {:ok, %{path: other}, _content} -> {:error, {:swap_belongs_to, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        %EditorState{} = state,
        %Outcome{
          value: {:completed, {source, content}},
          request: %Request{effect: %__MODULE__{} = effect}
        } = outcome
      ),
      do: {reopen(state, effect, source, content), outcome}

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

  @spec reopen(EditorState.t(), t(), Swap.identity(), String.t()) :: EditorState.t()
  defp reopen(state, %__MODULE__{} = effect, %{path: path} = source, content) do
    case start_with_text(state, source, content) do
      {:ok, buffer} ->
        Log.info(:editor, "Recovered after a crash: #{Path.basename(path)}")

        state
        |> register(buffer, path, effect.activate?)
        |> EditorState.mark_buffer_crash_recovered(buffer)
        |> NoticeWorkflow.publish(
          "#{Path.basename(path)} was reopened with its unsaved text after its buffer crashed"
        )

      {:error, :modified} ->
        Log.warning(
          :editor,
          "#{path} is open again with newer unsaved text, so its text from before the crash was not restored."
        )

        state

      {:error, :stale_swap} ->
        state

      {:error, reason} ->
        Log.warning(
          :editor,
          "Could not reopen #{path} with its unsaved text. It stays in #{effect.swap_path}: #{inspect(reason, limit: 5)}"
        )

        state
    end
  end

  # Gives the recovered text to the buffer for the file: the one that is open again, or a new one.
  # A buffer that started after the crash took the kept swap when it started, so it holds this text already.
  # If the user has typed in it since, it holds newer text and refuses.
  @spec start_with_text(EditorState.t(), Swap.identity(), String.t()) ::
          {:ok, pid()} | {:error, term()}
  defp start_with_text(state, source, content) do
    with {:ok, buffer} <- buffer_for(state, source.path, source.swap_path),
         :ok <- Buffer.adopt_recovered_text(buffer, content, source, :automatic) do
      {:ok, buffer}
    end
  catch
    # The buffer can stop between its lookup or start and the content call.
    # A new one is not monitored yet, so nothing else reports it.
    :exit, reason -> {:error, {:exit, reason}}
  end

  # A new buffer writes into the directory the crashed one used, so it owns the same swap file.
  # Saving or closing it removes the swap; a second crash rewrites it.
  @spec buffer_for(EditorState.t(), String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp buffer_for(state, path, swap_path) do
    case Buffer.pid_for_path(path) do
      {:ok, open_buffer} ->
        {:ok, open_buffer}

      :not_found ->
        Commands.start_buffer(path, state.interaction.options_server,
          events_registry: state.extension_surfaces.events_registry,
          swap_dir: Path.dirname(swap_path),
          allow_missing: true
        )
    end
  end

  @spec register(EditorState.t(), pid(), String.t(), boolean()) :: EditorState.t()
  defp register(state, buffer, path, activate?) do
    if BufferRegistry.buffer_tracked?(state, buffer),
      do: state,
      else: register_new(state, buffer, path, activate?)
  end

  @spec register_new(EditorState.t(), pid(), String.t(), boolean()) :: EditorState.t()
  defp register_new(state, buffer, path, true),
    do: BufferRegistry.register_buffer(state, buffer, path)

  defp register_new(state, buffer, path, false),
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

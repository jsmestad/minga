defmodule MingaAdversarial.Watcher do
  @moduledoc """
  Owns the adversarial analysis lifecycle.

  Subscribes to save/change/close events. Analysis runs on demand (the
  `adversarial-analyze` command) and, when the skepticism dial is `:on_save`
  or `:paranoid`, on save. Each analysis runs the model off-process and
  publishes findings through `Minga.Extension.Diagnostics`.

  Two correctness guards matter:

    * **Stale-reply drop.** Each path carries a monotonic generation. An edit
      or a newer analysis bumps it; a model reply tagged with an older
      generation is discarded, so rapid saves never race conflicting findings
      into the gutter.
    * **Clear on edit/close.** Findings on a line you are editing are worse
      than none, so a user edit clears that file's findings immediately.

  Model and dispatch are injectable so the analysis path is testable without a
  network call.
  """

  use GenServer

  alias Minga.Buffer
  alias Minga.Events.BufferChangedEvent
  alias Minga.Events.BufferClosedEvent
  alias Minga.Events.BufferEvent
  alias Minga.Extension.AI
  alias Minga.Extension.Diagnostics
  alias MingaAdversarial.Findings
  alias MingaAdversarial.Prompt

  @extension_name :minga_adversarial
  @max_tokens 1024
  # Skip files larger than this; a background reviewer should not fan huge
  # files at the model. ponytail: flat byte cap, tune if it bites.
  @max_bytes 100_000
  @dial [:off, :manual, :on_save, :paranoid]

  @type skepticism :: :off | :manual | :on_save | :paranoid
  @type state :: %{
          skepticism_override: skepticism() | nil,
          ai_fun: (list(), pos_integer() -> {:ok, String.t()} | {:error, term()}),
          dispatch: ((-> any()) -> any()),
          generation: %{String.t() => non_neg_integer()},
          published: MapSet.t(String.t())
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Analyzes `path` now. Returns `:off` when the dial is off, else `:ok`."
  @spec analyze(GenServer.server(), String.t()) :: :ok | :off
  def analyze(server \\ __MODULE__, path) do
    GenServer.call(server, {:analyze, path})
  end

  @doc "Clears this extension's findings for `path`."
  @spec clear(GenServer.server(), String.t()) :: :ok
  def clear(server \\ __MODULE__, path) do
    GenServer.cast(server, {:clear, path})
  end

  @doc "Cycles the session skepticism dial and returns the new value."
  @spec cycle_skepticism(GenServer.server()) :: skepticism()
  def cycle_skepticism(server \\ __MODULE__) do
    GenServer.call(server, :cycle_skepticism)
  end

  # ── Server ───────────────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    Process.flag(:trap_exit, true)
    subscribe()

    {:ok,
     %{
       skepticism_override: Keyword.get(opts, :skepticism),
       ai_fun: Keyword.get(opts, :ai_fun, &default_complete/2),
       dispatch: Keyword.get(opts, :dispatch, &default_dispatch/1),
       generation: %{},
       published: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:analyze, path}, _from, state) do
    case skepticism(state) do
      :off -> {:reply, :off, state}
      skep -> {:reply, :ok, request(state, path, skep)}
    end
  end

  def handle_call(:cycle_skepticism, _from, state) do
    next = next_dial(skepticism(state))
    {:reply, next, %{state | skepticism_override: next}}
  end

  @impl true
  def handle_cast({:clear, path}, state) do
    {:noreply, clear_path(bump(state, path), path)}
  end

  @impl true
  def handle_info({:minga_event, :buffer_saved, %BufferEvent{path: path}}, state)
      when is_binary(path) do
    case skepticism(state) do
      skep when skep in [:on_save, :paranoid] -> {:noreply, request(state, path, skep)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(
        {:minga_event, :buffer_changed, %BufferChangedEvent{source: :user, buffer: buffer}},
        state
      ) do
    case safe_file_path(buffer) do
      nil -> {:noreply, state}
      path -> {:noreply, clear_path(bump(state, path), path)}
    end
  end

  def handle_info({:minga_event, :buffer_closed, %BufferClosedEvent{path: path}}, state)
      when is_binary(path) do
    {:noreply, clear_path(state, path)}
  end

  # Model reply, tagged with the path+generation it was requested for.
  def handle_info({:ai_result, path, gen, result}, state) do
    if Map.get(state.generation, path) == gen do
      {:noreply, deliver(state, path, result)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    Diagnostics.clear_all(@extension_name)
    :ok
  end

  # ── Analysis ─────────────────────────────────────────────────────────────

  @spec request(state(), String.t(), skepticism()) :: state()
  defp request(state, path, skep) do
    with {:ok, content} <- File.read(path),
         true <- byte_size(content) <= @max_bytes do
      state = bump(state, path)
      gen = Map.fetch!(state.generation, path)
      messages = Prompt.messages(path, content, skep)
      me = self()
      ai_fun = state.ai_fun

      state.dispatch.(fn ->
        send(me, {:ai_result, path, gen, ai_fun.(messages, @max_tokens)})
      end)

      state
    else
      _ -> state
    end
  end

  @spec deliver(state(), String.t(), {:ok, String.t()} | {:error, term()}) :: state()
  defp deliver(state, path, {:ok, text}) do
    case Findings.parse(text) do
      [] -> clear_path(state, path)
      findings -> publish(state, path, findings)
    end
  end

  # Silent on failure: leave whatever is already shown, surface nothing.
  defp deliver(state, _path, {:error, _reason}), do: state

  @spec publish(state(), String.t(), [Findings.finding()]) :: state()
  defp publish(state, path, findings) do
    Diagnostics.publish(@extension_name, path, findings)
    %{state | published: MapSet.put(state.published, path)}
  end

  @spec clear_path(state(), String.t()) :: state()
  defp clear_path(state, path) do
    if MapSet.member?(state.published, path) do
      Diagnostics.clear(@extension_name, path)
      %{state | published: MapSet.delete(state.published, path)}
    else
      state
    end
  end

  @spec bump(state(), String.t()) :: state()
  defp bump(state, path) do
    %{state | generation: Map.update(state.generation, path, 1, &(&1 + 1))}
  end

  # ── Skepticism dial ──────────────────────────────────────────────────────

  @spec skepticism(state()) :: skepticism()
  defp skepticism(%{skepticism_override: override}) when override in @dial, do: override
  defp skepticism(_state), do: configured_skepticism()

  @spec configured_skepticism() :: skepticism()
  defp configured_skepticism do
    case Minga.Config.Options.get_extension_option(@extension_name, :skepticism) do
      value when value in @dial -> value
      _ -> :manual
    end
  rescue
    _ -> :manual
  end

  @spec next_dial(skepticism()) :: skepticism()
  defp next_dial(current) do
    idx = Enum.find_index(@dial, &(&1 == current)) || 0
    Enum.at(@dial, rem(idx + 1, length(@dial)))
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec subscribe() :: :ok
  defp subscribe do
    Minga.Events.subscribe(:buffer_saved)
    Minga.Events.subscribe(:buffer_changed)
    Minga.Events.subscribe(:buffer_closed)
    :ok
  end

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(buffer) when is_pid(buffer) do
    Buffer.file_path(buffer)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_file_path(_buffer), do: nil

  @spec default_complete([map()], pos_integer()) :: {:ok, String.t()} | {:error, term()}
  defp default_complete(messages, max_tokens) do
    AI.complete(messages, max_tokens: max_tokens)
  end

  @spec default_dispatch((-> any())) :: :ok
  defp default_dispatch(thunk) do
    Task.start(thunk)
    :ok
  end
end

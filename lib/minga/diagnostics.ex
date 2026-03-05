defmodule Minga.Diagnostics do
  @moduledoc """
  Source-agnostic diagnostic framework.

  Any diagnostic producer — LSP servers, external linters, compilers, test
  runners — publishes diagnostics through this module. The display layer
  (gutter signs, picker, navigation, minibuffer hints) queries this module
  and doesn't know or care where diagnostics came from.

  Modeled on Neovim's `vim.diagnostic` and Emacs's `flymake`.

  ## Producer API

  Producers call `publish/3` to replace all diagnostics for a given
  `{source, uri}` pair:

      Diagnostics.publish(:lexical, "file:///path/to/file.ex", [%Diagnostic{...}])
      Diagnostics.publish(:mix_compile, "file:///path/to/file.ex", [%Diagnostic{...}])

  ## Consumer API

  The display layer queries merged diagnostics:

      Diagnostics.for_uri("file:///path/to/file.ex")  # sorted, all sources
      Diagnostics.severity_by_line("file:///...")       # highest per line
      Diagnostics.next("file:///...", current_line)     # next diagnostic
      Diagnostics.count("file:///...")                  # {error: N, ...}

  ## Subscriptions

  The Editor subscribes to receive `{:diagnostics_changed, uri}` messages
  when diagnostics are published or cleared, triggering re-renders.
  """

  use GenServer

  alias Minga.Diagnostics.Diagnostic

  defstruct store: %{}, subscribers: []

  @typedoc "A diagnostic source identifier (e.g., `:lexical`, `:mix_compile`)."
  @type source :: atom()

  @typedoc "A file URI string (e.g., `\"file:///path/to/file.ex\"`)."
  @type uri :: String.t()

  @typedoc "Internal state."
  @type state :: %__MODULE__{
          store: %{{source(), uri()} => [Diagnostic.t()]},
          subscribers: [pid()]
        }

  # ── Client API: Lifecycle ──────────────────────────────────────────────────

  @doc "Starts the diagnostics server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Subscribes the calling process to diagnostic change notifications.

  The subscriber receives `{:diagnostics_changed, uri}` messages whenever
  diagnostics are published or cleared for a URI.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  # ── Client API: Producers ──────────────────────────────────────────────────

  @doc """
  Publishes diagnostics for a `{source, uri}` pair.

  Replaces all existing diagnostics for this source+URI combination.
  Notifies subscribers with `{:diagnostics_changed, uri}`.
  """
  @spec publish(GenServer.server(), source(), uri(), [Diagnostic.t()]) :: :ok
  def publish(server \\ __MODULE__, source, uri, diagnostics)
      when is_atom(source) and is_binary(uri) and is_list(diagnostics) do
    GenServer.call(server, {:publish, source, uri, diagnostics})
  end

  @doc """
  Clears all diagnostics for a specific `{source, uri}` pair.

  Notifies subscribers with `{:diagnostics_changed, uri}`.
  """
  @spec clear(GenServer.server(), source(), uri()) :: :ok
  def clear(server \\ __MODULE__, source, uri)
      when is_atom(source) and is_binary(uri) do
    GenServer.call(server, {:clear, source, uri})
  end

  @doc """
  Clears all diagnostics from a specific source across all URIs.

  Notifies subscribers for each affected URI.
  """
  @spec clear_source(GenServer.server(), source()) :: :ok
  def clear_source(server \\ __MODULE__, source) when is_atom(source) do
    GenServer.call(server, {:clear_source, source})
  end

  # ── Client API: Consumers ──────────────────────────────────────────────────

  @doc """
  Returns all diagnostics for a URI, merged from all sources, sorted by
  line then column then severity.
  """
  @spec for_uri(GenServer.server(), uri()) :: [Diagnostic.t()]
  def for_uri(server \\ __MODULE__, uri) when is_binary(uri) do
    GenServer.call(server, {:for_uri, uri})
  end

  @doc """
  Returns the highest severity diagnostic per line for a URI.

  Used by the gutter renderer to pick the sign icon for each line.
  """
  @spec severity_by_line(GenServer.server(), uri()) :: %{
          non_neg_integer() => Diagnostic.severity()
        }
  def severity_by_line(server \\ __MODULE__, uri) when is_binary(uri) do
    GenServer.call(server, {:severity_by_line, uri})
  end

  @doc """
  Returns the next diagnostic after `current_line` for a URI, or `nil`.

  Wraps around to the first diagnostic if past the last one.
  """
  @spec next(GenServer.server(), uri(), non_neg_integer()) :: Diagnostic.t() | nil
  def next(server \\ __MODULE__, uri, current_line)
      when is_binary(uri) and is_integer(current_line) do
    GenServer.call(server, {:next, uri, current_line})
  end

  @doc """
  Returns the previous diagnostic before `current_line` for a URI, or `nil`.

  Wraps around to the last diagnostic if before the first one.
  """
  @spec prev(GenServer.server(), uri(), non_neg_integer()) :: Diagnostic.t() | nil
  def prev(server \\ __MODULE__, uri, current_line)
      when is_binary(uri) and is_integer(current_line) do
    GenServer.call(server, {:prev, uri, current_line})
  end

  @doc """
  Returns diagnostic counts by severity for a URI.

  Useful for modeline display (e.g., `E:2 W:1`).
  """
  @spec count(GenServer.server(), uri()) :: %{
          error: non_neg_integer(),
          warning: non_neg_integer(),
          info: non_neg_integer(),
          hint: non_neg_integer()
        }
  def count(server \\ __MODULE__, uri) when is_binary(uri) do
    GenServer.call(server, {:count, uri})
  end

  @doc """
  Returns all diagnostics on a specific line for a URI, from all sources.

  Useful for showing diagnostic messages in the minibuffer when the cursor
  is on a line with diagnostics.
  """
  @spec on_line(GenServer.server(), uri(), non_neg_integer()) :: [Diagnostic.t()]
  def on_line(server \\ __MODULE__, uri, line)
      when is_binary(uri) and is_integer(line) do
    GenServer.call(server, {:on_line, uri, line})
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, %__MODULE__{} = state) when is_pid(pid) do
    Process.monitor(pid)
    {:reply, :ok, %__MODULE__{state | subscribers: [pid | state.subscribers]}}
  end

  def handle_call({:publish, source, uri, diagnostics}, _from, %__MODULE__{} = state) do
    new_store = Map.put(state.store, {source, uri}, diagnostics)
    notify_subscribers(state.subscribers, uri)
    {:reply, :ok, %__MODULE__{state | store: new_store}}
  end

  def handle_call({:clear, source, uri}, _from, %__MODULE__{} = state) do
    new_store = Map.delete(state.store, {source, uri})
    notify_subscribers(state.subscribers, uri)
    {:reply, :ok, %__MODULE__{state | store: new_store}}
  end

  def handle_call({:clear_source, source}, _from, %__MODULE__{} = state) do
    {removed, kept} =
      state.store
      |> Map.split_with(fn {{src, _uri}, _diags} -> src == source end)

    affected_uris =
      removed
      |> Map.keys()
      |> Enum.map(fn {_src, uri} -> uri end)
      |> Enum.uniq()

    Enum.each(affected_uris, &notify_subscribers(state.subscribers, &1))
    {:reply, :ok, %__MODULE__{state | store: kept}}
  end

  def handle_call({:for_uri, uri}, _from, %__MODULE__{} = state) do
    {:reply, merged_for_uri(state.store, uri), state}
  end

  def handle_call({:severity_by_line, uri}, _from, %__MODULE__{} = state) do
    result =
      state.store
      |> merged_for_uri(uri)
      |> Enum.reduce(%{}, fn diag, acc ->
        line = diag.range.start_line

        Map.update(acc, line, diag.severity, fn existing ->
          Diagnostic.more_severe(existing, diag.severity)
        end)
      end)

    {:reply, result, state}
  end

  def handle_call({:next, uri, current_line}, _from, %__MODULE__{} = state) do
    diags = merged_for_uri(state.store, uri)
    result = find_next(diags, current_line)
    {:reply, result, state}
  end

  def handle_call({:prev, uri, current_line}, _from, %__MODULE__{} = state) do
    diags = merged_for_uri(state.store, uri)
    result = find_prev(diags, current_line)
    {:reply, result, state}
  end

  def handle_call({:count, uri}, _from, %__MODULE__{} = state) do
    counts =
      state.store
      |> merged_for_uri(uri)
      |> Enum.reduce(%{error: 0, warning: 0, info: 0, hint: 0}, fn diag, acc ->
        Map.update!(acc, diag.severity, &(&1 + 1))
      end)

    {:reply, counts, state}
  end

  def handle_call({:on_line, uri, line}, _from, %__MODULE__{} = state) do
    result =
      state.store
      |> merged_for_uri(uri)
      |> Enum.filter(fn diag -> diag.range.start_line == line end)

    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = state) do
    {:noreply, %__MODULE__{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec merged_for_uri(%{{source(), uri()} => [Diagnostic.t()]}, uri()) :: [Diagnostic.t()]
  defp merged_for_uri(store, uri) do
    store
    |> Enum.filter(fn {{_src, u}, _diags} -> u == uri end)
    |> Enum.flat_map(fn {_key, diags} -> diags end)
    |> Diagnostic.sort()
  end

  @spec find_next([Diagnostic.t()], non_neg_integer()) :: Diagnostic.t() | nil
  defp find_next([], _current_line), do: nil

  defp find_next(sorted_diags, current_line) do
    case Enum.find(sorted_diags, fn d -> d.range.start_line > current_line end) do
      nil -> List.first(sorted_diags)
      diag -> diag
    end
  end

  @spec find_prev([Diagnostic.t()], non_neg_integer()) :: Diagnostic.t() | nil
  defp find_prev([], _current_line), do: nil

  defp find_prev(sorted_diags, current_line) do
    case sorted_diags
         |> Enum.filter(fn d -> d.range.start_line < current_line end)
         |> List.last() do
      nil -> List.last(sorted_diags)
      diag -> diag
    end
  end

  @spec notify_subscribers([pid()], uri()) :: :ok
  defp notify_subscribers(subscribers, uri) do
    Enum.each(subscribers, &send(&1, {:diagnostics_changed, uri}))
  end
end

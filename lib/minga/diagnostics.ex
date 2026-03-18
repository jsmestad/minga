defmodule Minga.Diagnostics do
  @moduledoc """
  Source-agnostic diagnostic framework.

  Any diagnostic producer — LSP servers, external linters, compilers, test
  runners — publishes diagnostics through this module. The display layer
  (gutter signs, picker, navigation, minibuffer hints) queries this module
  and doesn't know or care where diagnostics came from.

  Backed by ETS with `read_concurrency: true` for lock-free reads on the
  render path. The GenServer owns the ETS table lifecycle and manages
  subscriber notifications. Reads go directly to ETS; writes go through
  the GenServer to serialize subscriber notifications.

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

  @typedoc "A diagnostic source identifier (e.g., `:lexical`, `:mix_compile`)."
  @type source :: atom()

  @typedoc "A file URI string (e.g., `\"file:///path/to/file.ex\"`)."
  @type uri :: String.t()

  @typedoc "Internal state: ETS table reference and subscriber list."
  @type state :: %{table: :ets.table(), subscribers: [pid()]}

  # ── Client API: Lifecycle ──────────────────────────────────────────────────

  @doc "Starts the diagnostics server and creates the backing ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
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

  # ── Client API: Producers (writes go through GenServer for subscriber notifications) ──

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

  # ── Client API: Consumers (reads go directly to ETS) ───────────────────────

  @doc """
  Returns all diagnostics for a URI, merged from all sources, sorted by
  line then column then severity.
  """
  @spec for_uri(GenServer.server(), uri()) :: [Diagnostic.t()]
  def for_uri(server \\ __MODULE__, uri) when is_binary(uri) do
    server
    |> table_name()
    |> merged_for_uri(uri)
  end

  @doc """
  Returns the highest severity diagnostic per line for a URI.

  Used by the gutter renderer to pick the sign icon for each line.
  """
  @spec severity_by_line(GenServer.server(), uri()) :: %{
          non_neg_integer() => Diagnostic.severity()
        }
  def severity_by_line(server \\ __MODULE__, uri) when is_binary(uri) do
    server
    |> table_name()
    |> merged_for_uri(uri)
    |> Enum.reduce(%{}, fn diag, acc ->
      line = diag.range.start_line

      Map.update(acc, line, diag.severity, fn existing ->
        Diagnostic.more_severe(existing, diag.severity)
      end)
    end)
  end

  @doc """
  Returns the next diagnostic after `current_line` for a URI, or `nil`.

  Wraps around to the first diagnostic if past the last one.
  """
  @spec next(GenServer.server(), uri(), non_neg_integer()) :: Diagnostic.t() | nil
  def next(server \\ __MODULE__, uri, current_line)
      when is_binary(uri) and is_integer(current_line) do
    server
    |> table_name()
    |> merged_for_uri(uri)
    |> find_next(current_line)
  end

  @doc """
  Returns the previous diagnostic before `current_line` for a URI, or `nil`.

  Wraps around to the last diagnostic if before the first one.
  """
  @spec prev(GenServer.server(), uri(), non_neg_integer()) :: Diagnostic.t() | nil
  def prev(server \\ __MODULE__, uri, current_line)
      when is_binary(uri) and is_integer(current_line) do
    server
    |> table_name()
    |> merged_for_uri(uri)
    |> find_prev(current_line)
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
    server
    |> table_name()
    |> merged_for_uri(uri)
    |> Enum.reduce(%{error: 0, warning: 0, info: 0, hint: 0}, fn diag, acc ->
      Map.update!(acc, diag.severity, &(&1 + 1))
    end)
  end

  @doc """
  Returns diagnostic counts as a tuple for the modeline, or nil if none.

  Returns `{errors, warnings, info, hints}` when any diagnostics exist,
  or `nil` when there are none. Used by both the TUI modeline and the
  GUI status bar protocol encoder.
  """
  @spec count_tuple(GenServer.server(), uri()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  def count_tuple(server \\ __MODULE__, uri) when is_binary(uri) do
    case count(server, uri) do
      %{error: 0, warning: 0, info: 0, hint: 0} -> nil
      %{error: e, warning: w, info: i, hint: h} -> {e, w, i, h}
    end
  end

  @doc """
  Returns all diagnostics on a specific line for a URI, from all sources.

  Useful for showing diagnostic messages in the minibuffer when the cursor
  is on a line with diagnostics.
  """
  @spec on_line(GenServer.server(), uri(), non_neg_integer()) :: [Diagnostic.t()]
  def on_line(server \\ __MODULE__, uri, line)
      when is_binary(uri) and is_integer(line) do
    server
    |> table_name()
    |> merged_for_uri(uri)
    |> Enum.filter(fn diag -> diag.range.start_line == line end)
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl GenServer
  @spec init(atom()) :: {:ok, state()}
  def init(name) do
    table = :ets.new(table_name(name), [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{table: table, subscribers: []}}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  def handle_call({:publish, source, uri, diagnostics}, _from, state) do
    :ets.insert(state.table, {{source, uri}, diagnostics})
    notify_subscribers(state.subscribers, uri)
    {:reply, :ok, state}
  end

  def handle_call({:clear, source, uri}, _from, state) do
    :ets.delete(state.table, {source, uri})
    notify_subscribers(state.subscribers, uri)
    {:reply, :ok, state}
  end

  def handle_call(:table_name, _from, state) do
    {:reply, state.table, state}
  end

  def handle_call({:clear_source, source}, _from, state) do
    # Find all keys for this source, collect affected URIs, then delete
    affected_uris =
      :ets.foldl(
        fn
          {{src, uri}, _diags}, acc when src == source -> MapSet.put(acc, uri)
          _other, acc -> acc
        end,
        MapSet.new(),
        state.table
      )

    :ets.match_delete(state.table, {{source, :_}, :_})
    Enum.each(affected_uris, &notify_subscribers(state.subscribers, &1))
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec merged_for_uri(:ets.table(), uri()) :: [Diagnostic.t()]
  defp merged_for_uri(table, uri) do
    :ets.foldl(
      fn
        {{_src, ^uri}, diags}, acc -> diags ++ acc
        _other, acc -> acc
      end,
      [],
      table
    )
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

  @spec table_name(GenServer.server()) :: atom()
  defp table_name(name) when is_atom(name), do: :"#{name}_ets"
  defp table_name(pid) when is_pid(pid), do: GenServer.call(pid, :table_name)
end

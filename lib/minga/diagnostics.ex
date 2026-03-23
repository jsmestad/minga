defmodule Minga.Diagnostics do
  @moduledoc """
  Source-agnostic diagnostic framework.

  Any diagnostic producer — LSP servers, external linters, compilers, test
  runners — publishes diagnostics through this module. The display layer
  (gutter signs, picker, navigation, minibuffer hints) queries this module
  and doesn't know or care where diagnostics came from.

  Backed by ETS with `read_concurrency: true` for lock-free reads on the
  render path. The GenServer owns the ETS table lifecycle and broadcasts
  change notifications via `Minga.Events`. Reads go directly to ETS;
  writes go through the GenServer to serialize event broadcasts.

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

  ## Notifications

  After each publish or clear, the GenServer broadcasts a
  `{:minga_event, :diagnostics_updated, %DiagnosticsUpdatedEvent{}}` event
  via `Minga.Events`. Subscribers (e.g., the Editor) react to re-render
  gutter signs and minibuffer hints.
  """

  use GenServer

  alias Minga.Diagnostics.Diagnostic

  @typedoc "A diagnostic source identifier (e.g., `:lexical`, `:mix_compile`)."
  @type source :: atom()

  @typedoc "A file URI string (e.g., `\"file:///path/to/file.ex\"`)."
  @type uri :: String.t()

  @typedoc "Internal state: ETS table references, merge cache, and generation counter."
  @type state :: %{
          table: :ets.table(),
          uri_index: :ets.table(),
          merge_cache: :ets.table(),
          generation: non_neg_integer()
        }

  # ── Client API: Lifecycle ──────────────────────────────────────────────────

  @doc "Starts the diagnostics server and creates the backing ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  # ── Client API: Producers (writes go through GenServer for event broadcasts) ──

  @doc """
  Publishes diagnostics for a `{source, uri}` pair.

  Replaces all existing diagnostics for this source+URI combination.
  Broadcasts `:diagnostics_updated` via `Minga.Events`.
  """
  @spec publish(GenServer.server(), source(), uri(), [Diagnostic.t()]) :: :ok
  def publish(server \\ __MODULE__, source, uri, diagnostics)
      when is_atom(source) and is_binary(uri) and is_list(diagnostics) do
    GenServer.call(server, {:publish, source, uri, diagnostics})
  end

  @doc """
  Clears all diagnostics for a specific `{source, uri}` pair.

  Broadcasts `:diagnostics_updated` via `Minga.Events`.
  """
  @spec clear(GenServer.server(), source(), uri()) :: :ok
  def clear(server \\ __MODULE__, source, uri)
      when is_atom(source) and is_binary(uri) do
    GenServer.call(server, {:clear, source, uri})
  end

  @doc """
  Clears all diagnostics from a specific source across all URIs.

  Broadcasts `:diagnostics_updated` for each affected URI.
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
  @spec init(atom() | pid()) :: {:ok, state()}
  def init(name) do
    tname = table_name(name)
    table = :ets.new(tname, [:set, :public, :named_table, read_concurrency: true])

    # Secondary index: maps URI → list of sources that have diagnostics for it.
    # Enables O(1) URI lookups instead of scanning the entire table.
    uri_index = :ets.new(:"#{tname}_uri_idx", [:set, :public, read_concurrency: true])

    # Merge cache: stores merged diagnostics per URI.
    # Invalidated on publish/clear for that URI only.
    merge_cache = :ets.new(:"#{tname}_cache", [:set, :public, read_concurrency: true])

    # Store refs so readers can find the secondary tables from the main table name.
    :persistent_term.put({__MODULE__, tname}, {uri_index, merge_cache})

    {:ok,
     %{
       table: table,
       uri_index: uri_index,
       merge_cache: merge_cache,
       generation: 0
     }}
  end

  @impl GenServer
  def handle_call({:publish, source, uri, diagnostics}, _from, state) do
    :ets.insert(state.table, {{source, uri}, diagnostics})
    update_uri_index(state.uri_index, uri, source, :add)
    invalidate_cache(state.merge_cache, uri)
    gen = state.generation + 1
    broadcast_diagnostics_updated(uri, source)
    {:reply, :ok, %{state | generation: gen}}
  end

  def handle_call({:clear, source, uri}, _from, state) do
    :ets.delete(state.table, {source, uri})
    update_uri_index(state.uri_index, uri, source, :remove)
    invalidate_cache(state.merge_cache, uri)
    gen = state.generation + 1
    broadcast_diagnostics_updated(uri, source)
    {:reply, :ok, %{state | generation: gen}}
  end

  def handle_call(:table_name, _from, state) do
    {:reply, state.table, state}
  end

  def handle_call(:table_refs, _from, state) do
    {:reply, {state.table, state.uri_index, state.merge_cache}, state}
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

    Enum.each(affected_uris, fn uri ->
      update_uri_index(state.uri_index, uri, source, :remove)
      invalidate_cache(state.merge_cache, uri)
    end)

    gen = state.generation + 1
    Enum.each(affected_uris, &broadcast_diagnostics_updated(&1, source))
    {:reply, :ok, %{state | generation: gen}}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  # Merged diagnostics for a URI, using the URI index for O(1) source
  # lookup and a generation-based cache to avoid re-merging on every call.
  @spec merged_for_uri(:ets.table(), uri()) :: [Diagnostic.t()]
  defp merged_for_uri(table, uri) do
    {uri_index, cache_table} = :persistent_term.get({__MODULE__, table})

    # Check cache first
    case :ets.lookup(cache_table, uri) do
      [{^uri, cached_diags}] ->
        cached_diags

      [] ->
        # Cache miss: look up sources for this URI, then fetch each
        result = merge_from_index(table, uri_index, uri)
        :ets.insert(cache_table, {uri, result})
        result
    end
  end

  @spec merge_from_index(:ets.table(), :ets.table(), uri()) :: [Diagnostic.t()]
  defp merge_from_index(table, uri_index, uri) do
    sources =
      case :ets.lookup(uri_index, uri) do
        [{^uri, src_list}] -> src_list
        [] -> []
      end

    sources
    |> Enum.flat_map(fn source ->
      case :ets.lookup(table, {source, uri}) do
        [{{^source, ^uri}, diags}] -> diags
        [] -> []
      end
    end)
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

  @spec update_uri_index(:ets.table(), uri(), source(), :add | :remove) :: :ok
  defp update_uri_index(uri_index, uri, source, :add) do
    case :ets.lookup(uri_index, uri) do
      [{^uri, sources}] ->
        unless source in sources do
          :ets.insert(uri_index, {uri, [source | sources]})
        end

      [] ->
        :ets.insert(uri_index, {uri, [source]})
    end

    :ok
  end

  defp update_uri_index(uri_index, uri, source, :remove) do
    case :ets.lookup(uri_index, uri) do
      [{^uri, sources}] ->
        new_sources = List.delete(sources, source)

        if new_sources == [] do
          :ets.delete(uri_index, uri)
        else
          :ets.insert(uri_index, {uri, new_sources})
        end

      [] ->
        :ok
    end

    :ok
  end

  @spec invalidate_cache(:ets.table(), uri()) :: true
  defp invalidate_cache(cache, uri) do
    :ets.delete(cache, uri)
  end

  @spec broadcast_diagnostics_updated(uri(), source()) :: :ok
  defp broadcast_diagnostics_updated(uri, source) do
    Minga.Events.broadcast(
      :diagnostics_updated,
      %Minga.Events.DiagnosticsUpdatedEvent{uri: uri, source: source}
    )
  end

  @spec table_name(GenServer.server()) :: atom()
  defp table_name(name) when is_atom(name), do: :"#{name}_ets"
  defp table_name(pid) when is_pid(pid), do: GenServer.call(pid, :table_name)
end

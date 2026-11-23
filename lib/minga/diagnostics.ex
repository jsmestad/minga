defmodule Minga.Diagnostics do
  @moduledoc """
  Source-agnostic diagnostic framework.

  Any diagnostic producer — LSP servers, external linters, compilers, test
  runners — publishes diagnostics through this module. The display layer
  (gutter signs, picker, navigation, minibuffer hints) queries this module
  and doesn't know or care where diagnostics came from.

  Backed by protected ETS tables with `read_concurrency: true` for lock-free reads on the render path. The GenServer is the only writer. Each write merges the URI's sources once and publishes one committed row holding a revision, the merged list, severity counts and gutter signs, plus one row per diagnostic line so line readers copy only that line. Readers only look up committed rows; they never populate caches. The row is written before the change is broadcast via `Minga.Events`.

  ## Revisions

  Every publication of a non-empty URI carries a fresh VM-unique positive revision from `:erlang.unique_integer/1`, so a revision never repeats across clears, republications of identical lists, or a restarted server. Revision `0` means the URI has no diagnostics. Clearing a URI deletes its row; no per-URI counter or tombstone survives. Consumers that retain derived state compare revisions with `changed_since/3` instead of copying an unchanged list.

  Modeled on Neovim's `vim.diagnostic` and Emacs's `flymake`.

  ## Producer API

  Producers call `publish/3` to replace all diagnostics for a given
  `{source, uri}` pair:

      Diagnostics.publish(:expert, "file:///path/to/file.ex", [%Diagnostic{...}])
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

  @typedoc "A diagnostic source identifier (e.g., `:expert`, `:mix_compile`)."
  @type source :: atom()

  @typedoc "A file URI string (e.g., `\"file:///path/to/file.ex\"`)."
  @type uri :: String.t()

  @typedoc "A committed publication revision. `0` means no diagnostics."
  @type revision :: non_neg_integer()

  @typedoc "Gutter sign per line: a severity, or `:diag_advisory` when only advisory diagnostics exist."
  @type gutter_signs :: %{non_neg_integer() => Diagnostic.severity() | :diag_advisory}

  @typedoc "Severity counts as `{errors, warnings, info, hints}`."
  @type count_tuple ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "Internal state: protected ETS table references."
  @type state :: %{
          table: :ets.table(),
          uri_index: :ets.table(),
          published: :ets.table(),
          lines: :ets.table()
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

  @doc "Returns one committed revision and its merged URI list, read atomically from the same row."
  @spec snapshot(GenServer.server(), uri()) :: {revision(), [Diagnostic.t()]}
  def snapshot(server \\ __MODULE__, uri) when is_binary(uri) do
    case server |> table_name() |> published_row(uri) do
      nil -> {0, []}
      {^uri, revision, diagnostics, _counts, _signs} -> {revision, diagnostics}
    end
  end

  @doc "Returns the committed revision for a URI without copying its diagnostics. `0` means none."
  @spec revision(GenServer.server(), uri()) :: revision()
  def revision(server \\ __MODULE__, uri) when is_binary(uri) do
    {_uri_index, published, _lines} = server |> table_name() |> secondary_tables()
    :ets.lookup_element(published, uri, 2, 0)
  end

  @doc """
  Returns the committed publication for a URI only when its revision differs from `known_revision`.

  An unchanged revision copies one integer and no diagnostic list. A changed revision returns the revision, merged list and gutter signs from the same committed row.
  """
  @spec changed_since(GenServer.server(), uri(), revision()) ::
          :unchanged | {:changed, revision(), [Diagnostic.t()], gutter_signs()}
  def changed_since(server \\ __MODULE__, uri, known_revision)
      when is_binary(uri) and is_integer(known_revision) and known_revision >= 0 do
    table = table_name(server)
    {_uri_index, published, _lines} = secondary_tables(table)

    if :ets.lookup_element(published, uri, 2, 0) == known_revision do
      :unchanged
    else
      changed_publication(published_row(table, uri), uri, known_revision)
    end
  end

  @spec changed_publication(tuple() | nil, uri(), revision()) ::
          :unchanged | {:changed, revision(), [Diagnostic.t()], gutter_signs()}
  defp changed_publication(nil, _uri, 0), do: :unchanged
  defp changed_publication(nil, _uri, _known), do: {:changed, 0, [], %{}}

  defp changed_publication({_uri, known, _diagnostics, _counts, _signs}, _uri2, known),
    do: :unchanged

  defp changed_publication({_uri, revision, diagnostics, _counts, signs}, _uri2, _known),
    do: {:changed, revision, diagnostics, signs}

  @doc "Counts diagnostics by severity."
  @spec severity_counts([Diagnostic.t()]) :: %{atom() => non_neg_integer()}
  def severity_counts(diagnostics) when is_list(diagnostics) do
    Enum.reduce(diagnostics, %{error: 0, warning: 0, info: 0, hint: 0}, fn diagnostic, counts ->
      Map.update!(counts, diagnostic.severity, &(&1 + 1))
    end)
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
  Returns the gutter sign per line for a URI: a severity for normal
  producers, or `:diag_advisory` for lines whose only diagnostics are
  advisory (`Diagnostic.advisory: true`, e.g. extension/LLM hints).

  Lines that carry any non-advisory diagnostic use that producer's most
  severe sign, so compiler/LSP signs always win over advice on the same
  line. Used by the gutter renderer to pick the sign icon.
  """
  @spec gutter_signs_by_line(GenServer.server(), uri()) :: %{
          non_neg_integer() => Diagnostic.severity() | :diag_advisory
        }
  def gutter_signs_by_line(server \\ __MODULE__, uri) when is_binary(uri) do
    {_uri_index, published, _lines} = server |> table_name() |> secondary_tables()
    :ets.lookup_element(published, uri, 5, %{})
  end

  @spec line_gutter_sign([Diagnostic.t()]) :: Diagnostic.severity() | :diag_advisory
  defp line_gutter_sign(diags) do
    case Enum.reject(diags, &advisory?/1) do
      [] -> :diag_advisory
      real -> real |> Enum.map(& &1.severity) |> Enum.reduce(&Diagnostic.more_severe/2)
    end
  end

  @spec advisory?(Diagnostic.t()) :: boolean()
  defp advisory?(%Diagnostic{advisory: advisory}), do: advisory == true

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
    case count_tuple(server, uri) do
      nil -> %{error: 0, warning: 0, info: 0, hint: 0}
      {e, w, i, h} -> %{error: e, warning: w, info: i, hint: h}
    end
  end

  @doc """
  Returns diagnostic counts as a tuple for the modeline, or nil if none.

  Returns `{errors, warnings, info, hints}` when any diagnostics exist,
  or `nil` when there are none. Used by both the TUI modeline and the
  GUI status bar protocol encoder.
  """
  @spec count_tuple(GenServer.server(), uri()) :: count_tuple() | nil
  def count_tuple(server \\ __MODULE__, uri) when is_binary(uri) do
    server
    |> table_name()
    |> count_tuple_from_table(uri)
  end

  @doc """
  Returns diagnostic count tuples for URIs under a prefix.

  This is used by project-level status surfaces, such as the file tree, to build a path-keyed diagnostic summary without scanning unrelated diagnostic payloads or walking the filesystem.
  """
  @spec count_tuples_by_uri_prefix(GenServer.server(), uri()) :: %{
          uri() => {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
        }
  def count_tuples_by_uri_prefix(server \\ __MODULE__, uri_prefix) when is_binary(uri_prefix) do
    server
    |> table_name()
    |> do_count_tuples_by_uri_prefix(uri_prefix)
  end

  @doc """
  Returns all diagnostics on a specific line for a URI, from all sources.

  Useful for showing diagnostic messages in the minibuffer when the cursor
  is on a line with diagnostics.
  """
  @spec on_line(GenServer.server(), uri(), non_neg_integer()) :: [Diagnostic.t()]
  def on_line(server \\ __MODULE__, uri, line)
      when is_binary(uri) and is_integer(line) do
    {_uri_index, _published, lines} = server |> table_name() |> secondary_tables()
    :ets.lookup_element(lines, {uri, line}, 2, [])
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl GenServer
  @spec init(atom() | pid()) :: {:ok, state()}
  def init(name) do
    tname = table_name(name)
    # All tables are protected: this process is their only writer.
    table = :ets.new(tname, [:set, :protected, :named_table, read_concurrency: true])

    # Secondary index: maps URI → list of sources that have diagnostics for it.
    # Enables O(1) URI lookups instead of scanning the entire table.
    uri_index = :ets.new(:"#{tname}_uri_idx", [:set, :protected, read_concurrency: true])

    # Committed publications: {uri, revision, merged, counts, signs}.
    # Written once per change, before the change is broadcast.
    published = :ets.new(:"#{tname}_published", [:set, :protected, read_concurrency: true])

    # Per-line projection of each committed list: {{uri, line}, diagnostics}.
    # Lets line readers copy only that line instead of the whole URI list.
    lines = :ets.new(:"#{tname}_lines", [:set, :protected, read_concurrency: true])

    # Store refs so readers can find the secondary tables from the main table name.
    :persistent_term.put({__MODULE__, tname}, {uri_index, published, lines})

    {:ok, %{table: table, uri_index: uri_index, published: published, lines: lines}}
  end

  @impl GenServer
  def handle_call({:publish, source, uri, diagnostics}, _from, state) do
    store_published_diagnostics(state, source, uri, diagnostics)
    commit_uri(state, uri)
    broadcast_diagnostics_updated(uri, source)
    {:reply, :ok, state}
  end

  def handle_call({:clear, source, uri}, _from, state) do
    :ets.delete(state.table, {source, uri})
    update_uri_index(state.uri_index, uri, source, :remove)
    commit_uri(state, uri)
    broadcast_diagnostics_updated(uri, source)
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

    Enum.each(affected_uris, fn uri ->
      update_uri_index(state.uri_index, uri, source, :remove)
      commit_uri(state, uri)
    end)

    Enum.each(affected_uris, &broadcast_diagnostics_updated(&1, source))
    {:reply, :ok, state}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  # Merges the URI's sources and replaces its committed row in one insert.
  # An empty merge deletes the row, so revision 0 needs no tombstone. Line
  # rows are replaced in one insert before the list row, and lines the new
  # list no longer has are removed after it, all before the broadcast.
  @spec commit_uri(state(), uri()) :: :ok
  defp commit_uri(state, uri) do
    previous_lines = state.published |> :ets.lookup_element(uri, 5, %{}) |> Map.keys()

    case merge_from_index(state.table, state.uri_index, uri) do
      [] ->
        :ets.delete(state.published, uri)
        delete_lines(state.lines, uri, previous_lines, %{})

      merged ->
        revision = :erlang.unique_integer([:positive, :monotonic])
        by_line = by_line(merged)
        :ets.insert(state.lines, Enum.map(by_line, fn {line, diags} -> {{uri, line}, diags} end))

        :ets.insert(
          state.published,
          {uri, revision, merged, counts(merged), gutter_signs(by_line)}
        )

        delete_lines(state.lines, uri, previous_lines, by_line)
    end
  end

  @spec delete_lines(:ets.table(), uri(), [non_neg_integer()], map()) :: :ok
  defp delete_lines(lines, uri, previous_lines, retained) do
    Enum.each(previous_lines, fn line ->
      unless Map.has_key?(retained, line), do: :ets.delete(lines, {uri, line})
    end)
  end

  # Groups the merged list by start line, preserving published order and duplicates.
  @spec by_line([Diagnostic.t()]) :: %{non_neg_integer() => [Diagnostic.t()]}
  defp by_line(merged) do
    merged
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn diag, acc ->
      Map.update(acc, diag.range.start_line, [diag], &[diag | &1])
    end)
  end

  @spec gutter_signs(%{non_neg_integer() => [Diagnostic.t()]}) :: gutter_signs()
  defp gutter_signs(by_line),
    do: Map.new(by_line, fn {line, diags} -> {line, line_gutter_sign(diags)} end)

  @spec counts([Diagnostic.t()]) :: count_tuple()
  defp counts(merged) do
    Enum.reduce(merged, {0, 0, 0, 0}, fn
      %{severity: :error}, {e, w, i, h} -> {e + 1, w, i, h}
      %{severity: :warning}, {e, w, i, h} -> {e, w + 1, i, h}
      %{severity: :info}, {e, w, i, h} -> {e, w, i + 1, h}
      %{severity: :hint}, {e, w, i, h} -> {e, w, i, h + 1}
    end)
  end

  @spec store_published_diagnostics(state(), source(), uri(), [Diagnostic.t()]) :: :ok
  defp store_published_diagnostics(state, source, uri, []) do
    :ets.delete(state.table, {source, uri})
    update_uri_index(state.uri_index, uri, source, :remove)
  end

  defp store_published_diagnostics(state, source, uri, diagnostics) do
    :ets.insert(state.table, {{source, uri}, diagnostics})
    update_uri_index(state.uri_index, uri, source, :add)
  end

  @spec secondary_tables(:ets.table()) :: {:ets.table(), :ets.table(), :ets.table()}
  defp secondary_tables(table), do: :persistent_term.get({__MODULE__, table})

  @spec published_row(:ets.table(), uri()) :: tuple() | nil
  defp published_row(table, uri) do
    {_uri_index, published, _lines} = secondary_tables(table)

    case :ets.lookup(published, uri) do
      [row] -> row
      [] -> nil
    end
  end

  # Committed merged diagnostics for a URI. Readers never write.
  @spec merged_for_uri(:ets.table(), uri()) :: [Diagnostic.t()]
  defp merged_for_uri(table, uri) do
    {_uri_index, published, _lines} = secondary_tables(table)
    :ets.lookup_element(published, uri, 3, [])
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

  @spec do_count_tuples_by_uri_prefix(:ets.table(), uri()) :: %{
          uri() => {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
        }
  defp do_count_tuples_by_uri_prefix(table, uri_prefix) do
    {uri_index, _published, _lines} = secondary_tables(table)

    :ets.foldl(
      fn {uri, _sources}, acc ->
        maybe_put_count_tuple(acc, table, uri, uri_prefix)
      end,
      %{},
      uri_index
    )
  end

  @spec maybe_put_count_tuple(map(), :ets.table(), uri(), uri()) :: map()
  defp maybe_put_count_tuple(acc, table, uri, uri_prefix) do
    if uri_under_prefix?(uri, uri_prefix) do
      case count_tuple_from_table(table, uri) do
        nil -> acc
        counts -> Map.put(acc, uri, counts)
      end
    else
      acc
    end
  end

  @spec uri_under_prefix?(uri(), uri()) :: boolean()
  defp uri_under_prefix?(uri, uri_prefix),
    do: uri == uri_prefix or String.starts_with?(uri, prefix_dir(uri_prefix))

  @spec prefix_dir(uri()) :: uri()
  defp prefix_dir(uri_prefix) do
    if String.ends_with?(uri_prefix, "/"), do: uri_prefix, else: uri_prefix <> "/"
  end

  # A committed row is never empty, so its counts are never all zero.
  @spec count_tuple_from_table(:ets.table(), uri()) :: count_tuple() | nil
  defp count_tuple_from_table(table, uri) do
    {_uri_index, published, _lines} = secondary_tables(table)
    :ets.lookup_element(published, uri, 4, nil)
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
         |> Enum.at(-1) do
      nil -> Enum.at(sorted_diags, -1)
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

  @spec broadcast_diagnostics_updated(uri(), source()) :: :ok
  defp broadcast_diagnostics_updated(uri, source) do
    Minga.Events.broadcast(
      :diagnostics_updated,
      %Minga.Events.DiagnosticsUpdatedEvent{uri: uri, source: source},
      Minga.Events.default_registry()
    )
  end

  @spec table_name(GenServer.server()) :: atom()
  defp table_name(name) when is_atom(name), do: :"#{name}_ets"
  defp table_name(pid) when is_pid(pid), do: GenServer.call(pid, :table_name)
end

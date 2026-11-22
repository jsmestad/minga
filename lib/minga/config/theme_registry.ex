defmodule Minga.Config.ThemeRegistry do
  @moduledoc """
  Registry of available themes with source-owned registration, and the sole writer of that registry.

  Stores theme data (opaque to this module) with source ownership tracking so that disabling or reloading an extension pack cleanly removes only that pack's themes. The core minimal theme (`:minga_default`) is always present in the name list but not stored here; it lives in `MingaEditor.UI.Theme.Fallback` and is only used when selected explicitly.

  Registrations arrive from several processes: bundled theme packs while Foundation starts, extensions, the config loader during a reload, and contribution cleanup. Each change is a read-modify-write of one snapshot, so two unsynchronized writers can lose an update. This GenServer serializes every change and publishes the complete result as one `:persistent_term` snapshot. It skips the publish when nothing changes.

  Reads never call this process. `available/0`, `get_theme/1`, `stored_themes/0`, and `stored_sources/0` read the published snapshot directly. Before the owner starts, reads see an empty registry that names only the fallback theme. The owner publishes that empty snapshot in `init/1` when nothing is published yet, and adopts the published snapshot when it restarts.

  The owner makes no calls to other processes while it handles a request, so a caller that runs inside a pack or extension `init` cannot deadlock with it. `register_themes/2` registers its contribution cleanup callback in the calling process before it calls the owner.

  Config.Options and Config.Completion query `available/0` for validation and tab-completion without importing from MingaEditor.*.
  """

  use GenServer

  @persistent_key {__MODULE__, :snapshot}
  @fallback :minga_default
  @empty_snapshot %{entries: %{}, names: [@fallback]}

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:extension, atom()}

  @typedoc "Duplicate name error tuple."
  @type register_error ::
          {:duplicate_name, atom(), existing_source :: contribution_source(),
           attempted_source :: contribution_source()}

  @typep entries :: %{atom() => {contribution_source(), term()}}
  @typep snapshot :: %{entries: entries(), names: [atom()]}

  @doc "Starts the theme registry owner. It adopts a snapshot that survived a restart."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Returns the sorted list of available theme name atoms."
  @spec available() :: [atom()]
  def available do
    snapshot().names
  end

  @doc "Registers themes with explicit source ownership. Theme data is opaque to this module."
  @spec register_themes(%{atom() => term()}, contribution_source()) ::
          :ok | {:error, register_error()}
  def register_themes(themes, source) when is_map(themes) do
    Minga.Extension.ContributionCleanup.register(:themes, &__MODULE__.unregister_source/1)
    GenServer.call(__MODULE__, {:register, themes, source})
  end

  @doc "Removes every theme contributed by a source."
  @spec unregister_source(contribution_source()) :: :ok
  def unregister_source(:builtin), do: :ok
  def unregister_source(source), do: GenServer.call(__MODULE__, {:unregister_source, source})

  @doc "Returns the map of all registered theme data (opaque to callers in this layer)."
  @spec stored_themes() :: %{atom() => term()}
  def stored_themes do
    Map.new(snapshot().entries, fn {name, {_source, data}} -> {name, data} end)
  end

  @doc "Returns source ownership metadata."
  @spec stored_sources() :: %{atom() => contribution_source()}
  def stored_sources do
    Map.new(snapshot().entries, fn {name, {source, _data}} -> {name, source} end)
  end

  @doc "Looks up theme data by name."
  @spec get_theme(atom()) :: {:ok, term()} | :error
  def get_theme(name) when is_atom(name) do
    case Map.fetch(snapshot().entries, name) do
      {:ok, {_source, data}} -> {:ok, data}
      :error -> :error
    end
  end

  @impl true
  @spec init(:ok) :: {:ok, snapshot()}
  def init(:ok) do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> {:ok, publish(@empty_snapshot)}
      published -> {:ok, published}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), snapshot()) ::
          {:reply, :ok | {:error, register_error()}, snapshot()}
  def handle_call({:register, themes, source}, _from, snapshot) do
    case validate_sources(themes, snapshot.entries, source) do
      :ok ->
        entries =
          Enum.reduce(themes, remove_owned(snapshot.entries, source), fn {name, data}, acc ->
            Map.put(acc, name, {source, data})
          end)

        {:reply, :ok, publish_changed(snapshot, entries)}

      {:error, _reason} = error ->
        {:reply, error, snapshot}
    end
  end

  def handle_call({:unregister_source, source}, _from, snapshot) do
    {:reply, :ok, publish_changed(snapshot, remove_owned(snapshot.entries, source))}
  end

  @spec snapshot() :: snapshot()
  defp snapshot, do: :persistent_term.get(@persistent_key, @empty_snapshot)

  # Every :persistent_term write triggers a global literal-area scan, so an unchanged registry is not republished.
  @spec publish_changed(snapshot(), entries()) :: snapshot()
  defp publish_changed(%{entries: entries} = snapshot, entries), do: snapshot
  defp publish_changed(_snapshot, entries), do: publish(build_snapshot(entries))

  @spec build_snapshot(entries()) :: snapshot()
  defp build_snapshot(entries) do
    registered = Map.keys(entries)
    names = if Map.has_key?(entries, @fallback), do: registered, else: [@fallback | registered]
    %{entries: entries, names: Enum.sort(names)}
  end

  @spec publish(snapshot()) :: snapshot()
  defp publish(snapshot) do
    :persistent_term.put(@persistent_key, snapshot)
    snapshot
  end

  @spec remove_owned(entries(), contribution_source()) :: entries()
  defp remove_owned(entries, source) do
    :maps.fold(
      fn
        name, {^source, _data}, acc -> Map.delete(acc, name)
        _name, _entry, acc -> acc
      end,
      entries,
      entries
    )
  end

  @spec validate_sources(%{atom() => term()}, entries(), contribution_source()) ::
          :ok | {:error, register_error()}
  defp validate_sources(themes, entries, source) do
    Enum.reduce_while(themes, :ok, fn {name, _data}, :ok ->
      validate_source(name, entries, source)
    end)
  end

  @spec validate_source(atom(), entries(), contribution_source()) ::
          {:cont, :ok} | {:halt, {:error, register_error()}}
  defp validate_source(name, entries, source) do
    case Map.fetch(entries, name) do
      :error ->
        {:cont, :ok}

      {:ok, {^source, _data}} ->
        {:cont, :ok}

      {:ok, {existing, _data}} ->
        if source_overrides?(source, existing),
          do: {:cont, :ok},
          else: {:halt, {:error, {:duplicate_name, name, existing, source}}}
    end
  end

  @spec source_overrides?(contribution_source(), contribution_source()) :: boolean()
  defp source_overrides?(:config, {:extension, _}), do: true
  defp source_overrides?(_, _), do: false
end

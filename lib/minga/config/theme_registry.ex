defmodule Minga.Config.ThemeRegistry do
  @moduledoc """
  Layer 0 registry of available themes with source-owned registration.

  Stores theme data (opaque to this module) with source ownership tracking so that disabling or reloading an extension pack cleanly removes only that pack's themes. The core minimal theme (`:minga_default`) is always present in the name list but not stored here; it lives in `MingaEditor.UI.Theme.Fallback` and is only used when selected explicitly.

  Theme data, ownership, and available names are published in a single snapshot.
  Publication does not serialize concurrent writers or pin separate reads to one snapshot.

  Config.Options and Config.Completion query `available/0` for validation and tab-completion without importing from MingaEditor.*.
  """

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

  @doc "Returns the sorted list of available theme name atoms."
  @spec available() :: [atom()]
  def available do
    snapshot().names
  end

  @doc "Seeds the registry with the core fallback theme. Called at application start."
  @spec seed_builtin() :: :ok
  def seed_builtin do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> :persistent_term.put(@persistent_key, @empty_snapshot)
      _snapshot -> :ok
    end
  end

  @doc "Registers themes with explicit source ownership. Theme data is opaque to this module."
  @spec register_themes(%{atom() => term()}, contribution_source()) ::
          :ok | {:error, register_error()}
  def register_themes(themes, source) when is_map(themes) do
    Minga.Extension.ContributionCleanup.register(:themes, &__MODULE__.unregister_source/1)
    current = snapshot().entries

    with :ok <- validate_sources(themes, current, source) do
      remaining = remove_owned(current, source)

      entries =
        Enum.reduce(themes, remaining, fn {name, data}, acc ->
          Map.put(acc, name, {source, data})
        end)

      publish(entries)
    end
  end

  @doc "Removes every theme contributed by a source."
  @spec unregister_source(contribution_source()) :: :ok
  def unregister_source(:builtin), do: :ok

  def unregister_source(source) do
    snapshot().entries
    |> remove_owned(source)
    |> publish()
  end

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

  @spec snapshot() :: snapshot()
  defp snapshot, do: :persistent_term.get(@persistent_key, @empty_snapshot)

  @spec publish(entries()) :: :ok
  defp publish(entries) do
    registered = Map.keys(entries)
    names = if Map.has_key?(entries, @fallback), do: registered, else: [@fallback | registered]
    :persistent_term.put(@persistent_key, %{entries: entries, names: Enum.sort(names)})
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

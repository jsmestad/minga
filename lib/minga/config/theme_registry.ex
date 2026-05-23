defmodule Minga.Config.ThemeRegistry do
  @moduledoc """
  Layer 0 registry of available themes with source-owned registration.

  Stores theme data (opaque to this module) with source ownership tracking so that disabling or reloading an extension pack cleanly removes only that pack's themes. The core fallback theme (`:minga_default`) is always present in the name list but not stored here; it lives in `MingaEditor.UI.Theme.Fallback`.

  Config.Options and Config.Completion query `available/0` for validation and tab-completion without importing from MingaEditor.*.
  """

  @persistent_key :minga_theme_registry
  @themes_key {__MODULE__, :themes}
  @sources_key {__MODULE__, :sources}

  @fallback [:minga_default]

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:extension, atom()}

  @typedoc "Duplicate name error tuple."
  @type register_error ::
          {:duplicate_name, atom(), existing_source :: contribution_source(),
           attempted_source :: contribution_source()}

  @doc "Returns the sorted list of available theme name atoms."
  @spec available() :: [atom()]
  def available do
    :persistent_term.get(@persistent_key, @fallback)
  end

  @doc "Seeds the registry with the core fallback theme. Called at application start."
  @spec seed_builtin() :: :ok
  def seed_builtin do
    update_name_list()
  end

  @doc "Registers themes with explicit source ownership. Theme data is opaque to this module."
  @spec register_themes(%{atom() => term()}, contribution_source()) ::
          :ok | {:error, register_error()}
  def register_themes(themes, source) when is_map(themes) do
    Minga.Extension.ContributionCleanup.register(:themes, &__MODULE__.unregister_source/1)
    current = stored_themes()
    current_sources = stored_sources()

    with :ok <- validate_sources(themes, current_sources, source) do
      owned_names = owned_names(current_sources, source)
      remaining_themes = Map.drop(current, owned_names)
      remaining_sources = Map.drop(current_sources, owned_names)

      {new_themes, new_sources} =
        Enum.reduce(themes, {remaining_themes, remaining_sources}, fn {name, data},
                                                                      {theme_acc, source_acc} ->
          {Map.put(theme_acc, name, data), Map.put(source_acc, name, source)}
        end)

      :persistent_term.put(@themes_key, new_themes)
      :persistent_term.put(@sources_key, new_sources)
      update_name_list()
      :ok
    end
  end

  @doc "Removes every theme contributed by a source."
  @spec unregister_source(contribution_source()) :: :ok
  def unregister_source(:builtin), do: :ok

  def unregister_source(source) do
    sources = stored_sources()

    names =
      sources
      |> Enum.filter(fn {_name, entry_source} -> entry_source == source end)
      |> Enum.map(fn {name, _entry_source} -> name end)

    :persistent_term.put(@themes_key, Map.drop(stored_themes(), names))
    :persistent_term.put(@sources_key, Map.drop(sources, names))
    update_name_list()
    :ok
  end

  @doc "Returns the map of all registered theme data (opaque to callers in this layer)."
  @spec stored_themes() :: %{atom() => term()}
  def stored_themes do
    :persistent_term.get(@themes_key, %{})
  end

  @doc "Returns source ownership metadata."
  @spec stored_sources() :: %{atom() => contribution_source()}
  def stored_sources do
    :persistent_term.get(@sources_key, %{})
  end

  @doc "Looks up theme data by name."
  @spec get_theme(atom()) :: {:ok, term()} | :error
  def get_theme(name) when is_atom(name) do
    Map.fetch(stored_themes(), name)
  end

  @spec update_name_list() :: :ok
  defp update_name_list do
    registered = Map.keys(stored_themes())
    themes = Enum.uniq(@fallback ++ registered) |> Enum.sort()
    :persistent_term.put(@persistent_key, themes)
    :ok
  end

  @spec owned_names(%{atom() => contribution_source()}, contribution_source()) :: [atom()]
  defp owned_names(current_sources, source) do
    current_sources
    |> Enum.filter(fn {_name, entry_source} -> entry_source == source end)
    |> Enum.map(fn {name, _entry_source} -> name end)
  end

  @spec validate_sources(
          %{atom() => term()},
          %{atom() => contribution_source()},
          contribution_source()
        ) :: :ok | {:error, register_error()}
  defp validate_sources(themes, current_sources, source) do
    Enum.reduce_while(themes, :ok, fn {name, _data}, :ok ->
      validate_source(name, current_sources, source)
    end)
  end

  @spec validate_source(atom(), %{atom() => contribution_source()}, contribution_source()) ::
          {:cont, :ok} | {:halt, {:error, register_error()}}
  defp validate_source(name, current_sources, source) do
    case Map.get(current_sources, name) do
      nil ->
        {:cont, :ok}

      ^source ->
        {:cont, :ok}

      existing ->
        if source_overrides?(source, existing),
          do: {:cont, :ok},
          else: {:halt, {:error, {:duplicate_name, name, existing, source}}}
    end
  end

  @spec source_overrides?(contribution_source(), contribution_source()) :: boolean()
  defp source_overrides?(:config, {:extension, _}), do: true
  defp source_overrides?(_, _), do: false
end

defmodule Minga.Extensions.LanguagePacks do
  @moduledoc """
  Starts bundled language packs and registers their catalog data through extension-owned sources.

  Bundled packs use the same `Minga.Language.Registry.register/2` path as third-party language packs. Each `%Minga.Language{}` carries its own extensions, filenames, shebangs, devicon, grammar, formatter, and LSP defaults, so stopping or reloading a pack removes the whole language record from the registry instead of leaving stale derived data behind.
  """

  use Agent

  alias Minga.Extensions.PackLoader
  alias Minga.Language
  alias Minga.Language.Registry, as: LanguageRegistry

  @typedoc "A module that implements the language-pack extension callbacks."
  @type pack_module :: module()

  @typedoc "Runtime state for the bundled pack starter."
  @type state :: %{loaded: [atom()], failed: [{atom(), term()}]}

  @typedoc "Pack validation error when two language definitions claim the same key."
  @type pack_validation_error :: {:duplicate_pack_key, term(), module(), module()}

  @packs [Minga.Extensions.LanguagePacks.Bundled]

  @doc "Starts the bundled language pack loader."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    packs = Keyword.get(opts, :packs, @packs)
    disabled = Keyword.get(opts, :disabled, disabled_pack_names())

    Agent.start_link(fn -> load_packs(packs, disabled) end, name: name)
  end

  @doc "Returns bundled language pack modules in startup order."
  @spec packs() :: [pack_module()]
  def packs, do: @packs

  @doc "Registers all languages owned by a pack, replacing stale entries from an earlier load."
  @spec register_pack(pack_module()) :: :ok | {:error, term()}
  def register_pack(pack_module) when is_atom(pack_module) do
    source = source_for(pack_module)

    case collect_pack_languages(pack_module) do
      {:ok, languages} -> register_collected_pack(languages, source)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Unregisters all language catalog data owned by a pack."
  @spec unregister_pack(pack_module()) :: :ok
  def unregister_pack(pack_module) when is_atom(pack_module) do
    LanguageRegistry.unregister_source(source_for(pack_module))
  end

  @doc "Reloads a pack by removing its previous source-owned entries, then registering its current modules."
  @spec reload_pack(pack_module()) :: :ok | {:error, term()}
  def reload_pack(pack_module) when is_atom(pack_module), do: register_pack(pack_module)

  @doc "Returns the contribution source used for a pack."
  @spec source_for(pack_module()) :: {:extension, atom()}
  def source_for(pack_module) when is_atom(pack_module), do: {:extension, pack_module.name()}

  @spec load_packs([pack_module()], [atom()]) :: state()
  defp load_packs(packs, disabled), do: PackLoader.load(packs, disabled, __MODULE__, "Language")

  @spec disabled_pack_names() :: [atom()]
  defp disabled_pack_names do
    Application.get_env(:minga, :disabled_language_packs, [])
  end

  @spec register_collected_pack([Language.t()], LanguageRegistry.contribution_source()) ::
          :ok | {:error, term()}
  defp register_collected_pack(languages, source) do
    LanguageRegistry.unregister_source(source)

    languages
    |> Enum.reduce_while(:ok, &register_collected_language(&1, &2, source))
    |> cleanup_failed_register(source)
  end

  @spec register_collected_language(Language.t(), :ok, LanguageRegistry.contribution_source()) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp register_collected_language(%Language{} = lang, :ok, source) do
    case LanguageRegistry.register(lang, source) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec collect_pack_languages(pack_module()) ::
          {:ok, [Language.t()]} | {:error, pack_validation_error()}
  defp collect_pack_languages(pack_module) do
    pack_module.language_modules()
    |> Enum.reduce_while({[], %{}}, fn mod, {languages, seen} ->
      lang = mod.definition()

      case validate_pack_language_keys(lang, mod, seen) do
        {:ok, next_seen} -> {:cont, {[lang | languages], next_seen}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {languages, _seen} -> {:ok, Enum.reverse(languages)}
    end
  end

  @spec validate_pack_language_keys(
          Language.t(),
          module(),
          map()
        ) :: {:ok, map()} | {:error, pack_validation_error()}
  defp validate_pack_language_keys(%Language{} = lang, mod, seen) do
    lang
    |> Language.identity_keys()
    |> Enum.reduce_while(seen, &validate_pack_language_key(&1, &2, mod))
    |> normalize_pack_key_validation()
  end

  @spec validate_pack_language_key(term(), map(), module()) ::
          {:cont, map()} | {:halt, {:error, pack_validation_error()}}
  defp validate_pack_language_key(key, seen, mod) do
    case Map.fetch(seen, key) do
      {:ok, previous_mod} -> {:halt, {:error, {:duplicate_pack_key, key, previous_mod, mod}}}
      :error -> {:cont, Map.put(seen, key, mod)}
    end
  end

  @spec normalize_pack_key_validation(map() | {:error, pack_validation_error()}) ::
          {:ok, map()} | {:error, pack_validation_error()}
  defp normalize_pack_key_validation({:error, _reason} = error), do: error
  defp normalize_pack_key_validation(seen), do: {:ok, seen}

  @spec cleanup_failed_register(:ok | {:error, term()}, LanguageRegistry.contribution_source()) ::
          :ok | {:error, term()}
  defp cleanup_failed_register(:ok, _source), do: :ok

  defp cleanup_failed_register({:error, reason}, source) do
    LanguageRegistry.unregister_source(source)
    {:error, reason}
  end
end

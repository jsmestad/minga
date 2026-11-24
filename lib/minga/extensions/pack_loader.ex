defmodule Minga.Extensions.PackLoader do
  @moduledoc """
  Shared lifecycle for loading source-owned bundled extension packs.

  Each pack module (language, theme, recipe) delegates its startup, source tagging, and disabled-pack filtering to this module. The pack module itself keeps only its type-specific registration and collection logic.

  Registration runs synchronously during supervision startup and returns `:ignore`, so no idle registrar process remains after the catalog is loaded.
  """

  @type pack_module :: module()
  @type state :: %{loaded: [atom()], failed: [{atom(), term()}]}
  @type register_fn :: (pack_module() -> :ok | {:error, term()})
  @type unregister_fn :: (pack_module() -> :ok)

  @doc "Returns the contribution source used for a pack."
  @spec source_for(pack_module()) :: {:extension, atom()}
  def source_for(pack_module) when is_atom(pack_module), do: {:extension, pack_module.name()}

  @doc "Returns disabled pack names from the application environment."
  @spec disabled_pack_names(atom()) :: [atom()]
  def disabled_pack_names(env_key), do: Application.get_env(:minga, env_key, [])

  @doc """
  Synchronous startup action for bundled packs.

  Loads all enabled packs through the given registration functions, then returns `:ignore` so the supervisor records a successful start without retaining an idle process.
  """
  @spec start_link(keyword(), [pack_module()], atom(), register_fn(), unregister_fn(), String.t()) ::
          :ignore
  def start_link(opts, default_packs, disabled_env_key, register_fn, unregister_fn, kind) do
    packs = Keyword.get(opts, :packs, default_packs)
    disabled = Keyword.get(opts, :disabled, disabled_pack_names(disabled_env_key))
    load(packs, disabled, register_fn, unregister_fn, kind)
    :ignore
  end

  @doc "Loads enabled packs and records every failure."
  @spec load([pack_module()], [atom()], register_fn(), unregister_fn(), String.t()) :: state()
  def load(packs, disabled, register_fn, unregister_fn, kind) do
    Enum.reduce(packs, %{loaded: [], failed: []}, fn pack, state ->
      load_pack(pack, disabled, register_fn, unregister_fn, kind, state)
    end)
  end

  @spec load_pack(pack_module(), [atom()], register_fn(), unregister_fn(), String.t(), state()) ::
          state()
  defp load_pack(pack, disabled, register_fn, unregister_fn, kind, state) do
    name = pack.name()

    if name in disabled do
      unregister_fn.(pack)
      state
    else
      case register_fn.(pack) do
        :ok -> %{state | loaded: Enum.concat(state.loaded, [name])}
        {:error, reason} -> record_failed_pack(state, kind, name, reason)
      end
    end
  end

  @spec record_failed_pack(state(), String.t(), atom(), term()) :: state()
  defp record_failed_pack(state, kind, name, reason) do
    Minga.Log.warning(:config, "#{kind} pack #{name} failed to load: #{inspect(reason)}")
    %{state | failed: Enum.concat(state.failed, [{name, reason}])}
  end
end

defmodule Minga.Extensions.PackLoader do
  @moduledoc "Shared lifecycle for loading source-owned bundled extension packs."

  @type pack_module :: module()
  @type owner_module :: module()
  @type state :: %{loaded: [atom()], failed: [{atom(), term()}]}

  @doc "Loads enabled packs through their registry owner and records every failure."
  @spec load([pack_module()], [atom()], owner_module(), String.t()) :: state()
  def load(packs, disabled, owner, kind) do
    Enum.reduce(packs, %{loaded: [], failed: []}, fn pack, state ->
      load_pack(pack, disabled, owner, kind, state)
    end)
  end

  @spec load_pack(pack_module(), [atom()], owner_module(), String.t(), state()) :: state()
  defp load_pack(pack, disabled, owner, kind, state) do
    name = pack.name()

    if name in disabled do
      owner.unregister_pack(pack)
      state
    else
      case owner.register_pack(pack) do
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

defmodule Minga.Extension.Instance.Artifact do
  @moduledoc "Immutable current-generation artifact view and normalized runtime child policy."

  alias Minga.Extension.Manifest

  @type restart :: :permanent | :transient | :temporary

  @enforce_keys [:module, :manifest, :source, :owned_modules, :child_spec, :restart]
  defstruct [:module, :manifest, :source, :owned_modules, :child_spec, :restart]

  @type t :: %__MODULE__{
          module: module(),
          manifest: Manifest.t(),
          source: {:extension, atom()},
          owned_modules: [module()],
          child_spec: Supervisor.child_spec(),
          restart: restart()
        }

  @doc "Builds an artifact while preserving the declaration's original restart policy."
  @spec build(atom(), module(), Manifest.t(), [module()], keyword()) ::
          {:ok, t()} | {:error, term()}
  def build(name, module, manifest, owned_modules, config) do
    original =
      module.child_spec(config) |> Supervisor.child_spec([]) |> Map.put(:modules, [module])

    restart = Map.get(original, :restart, :permanent)

    if restart in [:permanent, :transient, :temporary] do
      {:ok,
       %__MODULE__{
         module: module,
         manifest: manifest,
         source: {:extension, name},
         owned_modules: Enum.sort(Enum.uniq(owned_modules)),
         child_spec: Map.put(original, :restart, :temporary),
         restart: restart
       }}
    else
      {:error, {:invalid_restart_policy, restart}}
    end
  rescue
    error -> {:error, {:child_spec_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:child_spec_failed, {kind, reason}}}
  end

  @doc "Returns whether a runtime exit should be replaced."
  @spec restart?(restart(), term()) :: boolean()
  def restart?(:permanent, _reason), do: true
  def restart?(:temporary, _reason), do: false
  def restart?(:transient, :normal), do: false
  def restart?(:transient, :shutdown), do: false
  def restart?(:transient, {:shutdown, _reason}), do: false
  def restart?(:transient, _reason), do: true

  @doc "Returns whether an exit is a crash for public lifecycle projection."
  @spec crash?(term()) :: boolean()
  def crash?(:normal), do: false
  def crash?(:shutdown), do: false
  def crash?({:shutdown, _reason}), do: false
  def crash?(_reason), do: true
end

defmodule Minga.Extension.Manifest do
  @moduledoc """
  Public declaration snapshot for an extension before runtime side effects run.

  Manifests are append-only data contracts. Callers can inspect what an extension declares, which source it came from, and which runtime capabilities it says it uses without invoking extension code beyond static callback/schema functions.
  """

  alias Minga.Extension

  @typedoc "Declared runtime/UI capability map. Keys are capability families and values are capability-specific terms."
  @type capabilities :: %{optional(atom()) => term()}

  @typedoc "How the extension source code is obtained."
  @type source_type :: :path | :git | :hex

  @enforce_keys [:name, :version, :source]
  defstruct [
    :name,
    :description,
    :version,
    :source,
    commands: [],
    keybindings: [],
    modeline_segments: [],
    capabilities: %{}
  ]

  @type t :: %__MODULE__{
          name: atom(),
          description: String.t() | nil,
          version: String.t(),
          source: source_type(),
          commands: [Extension.command_spec()],
          keybindings: [Extension.keybind_spec()],
          modeline_segments: [Extension.modeline_segment_spec()],
          capabilities: capabilities()
        }

  @doc "Builds a manifest from an extension module and source type."
  @spec from_module(module(), source_type()) :: t()
  def from_module(module, source) when is_atom(module) and source in [:path, :git, :hex] do
    %__MODULE__{
      name: module.name(),
      description: safe_description(module),
      version: module.version(),
      source: source,
      commands: safe_schema(module, :__command_schema__),
      keybindings: safe_schema(module, :__keybind_schema__),
      modeline_segments: safe_schema(module, :__modeline_segment_schema__),
      capabilities: safe_capabilities(module)
    }
  end

  @spec safe_description(module()) :: String.t() | nil
  defp safe_description(module) do
    if function_exported?(module, :description, 0), do: module.description(), else: nil
  end

  @spec safe_schema(module(), atom()) :: list()
  defp safe_schema(module, fun) do
    if function_exported?(module, fun, 0), do: apply(module, fun, []), else: []
  end

  @spec safe_capabilities(module()) :: capabilities()
  defp safe_capabilities(module) do
    if function_exported?(module, :__capability_schema__, 0),
      do: Map.new(module.__capability_schema__()),
      else: %{}
  end
end

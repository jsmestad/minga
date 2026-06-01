defmodule MingaAgent.Provider.Spec do
  @moduledoc """
  Pure provider declaration metadata.

  A provider spec describes a provider implementation without owning credentials, sessions, retries, events, or cleanup. Runtime enable/disable state belongs to `MingaAgent.ProviderRegistry`; this struct is the immutable contract a source contributes.
  """

  @typedoc "Source that contributed this provider."
  @type source :: :builtin | :config | {:extension, atom()}

  @typedoc "Provider capability advertised to the resolver and UI."
  @type capability :: atom()

  @typedoc "Credential requirement id. The credential broker decides how this is satisfied."
  @type credential_requirement :: atom()

  @enforce_keys [:source, :id, :module, :display_name]
  defstruct [
    :source,
    :id,
    :module,
    :display_name,
    model_prefixes: [],
    capabilities: [],
    credential_requirements: []
  ]

  @type t :: %__MODULE__{
          source: source(),
          id: String.t(),
          module: module(),
          display_name: String.t(),
          model_prefixes: [String.t()],
          capabilities: [capability()],
          credential_requirements: [credential_requirement()]
        }

  @doc "Builds and validates a provider spec."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    spec = %__MODULE__{
      source: Map.get(attrs, :source),
      id: Map.get(attrs, :id),
      module: Map.get(attrs, :module),
      display_name: Map.get(attrs, :display_name),
      model_prefixes: Map.get(attrs, :model_prefixes, []),
      capabilities: Map.get(attrs, :capabilities, []),
      credential_requirements: Map.get(attrs, :credential_requirements, [])
    }

    with :ok <- validate_source(spec.source),
         :ok <- validate_id(spec.id),
         :ok <- validate_module(spec.module),
         :ok <- validate_display_name(spec.display_name),
         :ok <- validate_string_list(:model_prefixes, spec.model_prefixes),
         :ok <- validate_atom_list(:capabilities, spec.capabilities),
         :ok <- validate_atom_list(:credential_requirements, spec.credential_requirements) do
      {:ok, spec}
    end
  end

  @doc "Builds a provider spec or raises on invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @spec validate_source(term()) :: :ok | {:error, term()}
  defp validate_source(:builtin), do: :ok
  defp validate_source(:config), do: :ok
  defp validate_source({:extension, name}) when is_atom(name), do: :ok
  defp validate_source(source), do: {:error, {:invalid_source, source}}

  @spec validate_id(term()) :: :ok | {:error, term()}
  defp validate_id(id) when is_binary(id) do
    if String.trim(id) == "" do
      {:error, {:invalid_id, id}}
    else
      :ok
    end
  end

  defp validate_id(id), do: {:error, {:invalid_id, id}}

  @spec validate_module(term()) :: :ok | {:error, term()}
  defp validate_module(module) when is_atom(module) and not is_nil(module), do: :ok
  defp validate_module(module), do: {:error, {:invalid_module, module}}

  @spec validate_display_name(term()) :: :ok | {:error, term()}
  defp validate_display_name(name) when is_binary(name) do
    if String.trim(name) == "" do
      {:error, {:invalid_display_name, name}}
    else
      :ok
    end
  end

  defp validate_display_name(name), do: {:error, {:invalid_display_name, name}}

  @spec validate_string_list(atom(), term()) :: :ok | {:error, term()}
  defp validate_string_list(_field, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: :ok, else: {:error, {:invalid_string_list, values}}
  end

  defp validate_string_list(field, values), do: {:error, {field, values}}

  @spec validate_atom_list(atom(), term()) :: :ok | {:error, term()}
  defp validate_atom_list(_field, values) when is_list(values) do
    if Enum.all?(values, &is_atom/1), do: :ok, else: {:error, {:invalid_atom_list, values}}
  end

  defp validate_atom_list(field, values), do: {:error, {field, values}}
end

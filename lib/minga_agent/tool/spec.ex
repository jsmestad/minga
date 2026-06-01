defmodule MingaAgent.Tool.Spec do
  @moduledoc """
  Source-owned declaration for an agent tool.

  A spec describes a tool and how to build its executable callback for a session. It does not own session state, credentials, approval decisions, events, or cleanup. Context-sensitive tools declare their requirements and receive a core-built `MingaAgent.Tool.Context` only when the executor has one.
  """

  @typedoc "Source that contributed this tool."
  @type source :: :builtin | :config | {:extension, atom()}

  @typedoc "Approval level for tool execution."
  @type approval_level :: :auto | :ask | :deny

  @typedoc "Tool category for grouping and filtering."
  @type category :: :filesystem | :git | :lsp | :shell | :memory | :agent | :network | :custom

  @typedoc "Capability advertised by a tool declaration."
  @type capability ::
          :read_project
          | :mutate_project
          | :run_shell
          | :network
          | :git_read
          | :git_mutate
          | :lsp_read
          | :lsp_mutate
          | :memory_write
          | :spawn_agent
          | atom()

  @typedoc "Runtime context required before a tool can be built."
  @type context_requirement :: :tool_context | :router | :project_root | :parent_session | atom()

  @typedoc "Executable provider-facing callback."
  @type callback :: (map() -> term())

  @typedoc "Builds an executable callback from a runtime context."
  @type build_fun :: (term() -> callback())

  @typedoc "A tool specification."
  @type t :: %__MODULE__{
          source: source(),
          name: String.t(),
          description: String.t(),
          parameter_schema: map(),
          callback: callback() | nil,
          build: build_fun(),
          category: category(),
          approval_level: approval_level(),
          capabilities: [capability()],
          context_requirements: [context_requirement()],
          metadata: map()
        }

  @mutating_capabilities [
    :mutate_project,
    :run_shell,
    :git_mutate,
    :lsp_mutate,
    :memory_write,
    :spawn_agent
  ]

  @enforce_keys [:source, :name, :description, :parameter_schema, :build]
  defstruct source: :config,
            name: nil,
            description: nil,
            parameter_schema: %{},
            callback: nil,
            build: nil,
            category: :custom,
            approval_level: :auto,
            capabilities: [],
            context_requirements: [],
            metadata: %{}

  @doc "Creates a new tool spec from a keyword list or map."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    source = Map.get(attrs, :source, :config)
    name = Map.get(attrs, :name)
    description = Map.get(attrs, :description)
    parameter_schema = Map.get(attrs, :parameter_schema, %{})
    callback = Map.get(attrs, :callback)
    build = Map.get(attrs, :build) || build_from_callback(callback)
    category = Map.get(attrs, :category, :custom)
    approval_level = Map.get(attrs, :approval_level, :auto)
    capabilities = Map.get(attrs, :capabilities, [])
    context_requirements = Map.get(attrs, :context_requirements, [])
    metadata = Map.get(attrs, :metadata, %{})

    with :ok <- validate_source(source),
         :ok <- validate_name(name),
         :ok <- validate_description(description),
         :ok <- validate_schema(parameter_schema),
         :ok <- validate_callback(callback),
         :ok <- validate_build(build),
         :ok <- validate_category(category),
         :ok <- validate_approval_level(approval_level),
         :ok <- validate_atom_list(:capabilities, capabilities),
         :ok <- validate_atom_list(:context_requirements, context_requirements),
         :ok <- validate_metadata(metadata),
         :ok <- validate_context_requirements(category, capabilities, context_requirements) do
      {:ok,
       %__MODULE__{
         source: source,
         name: name,
         description: description,
         parameter_schema: parameter_schema,
         callback: callback,
         build: build,
         category: category,
         approval_level: approval_level,
         capabilities: capabilities,
         context_requirements: context_requirements,
         metadata: metadata
       }}
    end
  end

  @doc "Creates a new tool spec, raising on validation failure."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @doc "Builds an executable callback for the given runtime context."
  @spec build_callback(t(), term()) :: callback()
  def build_callback(%__MODULE__{build: build}, context), do: build.(context)

  @spec build_from_callback(term()) :: build_fun() | nil
  defp build_from_callback(callback) when is_function(callback, 1),
    do: fn _context -> callback end

  defp build_from_callback(_callback), do: nil

  @spec validate_source(term()) :: :ok | {:error, term()}
  defp validate_source(:builtin), do: :ok
  defp validate_source(:config), do: :ok
  defp validate_source({:extension, name}) when is_atom(name), do: :ok
  defp validate_source(source), do: {:error, {:invalid_source, source}}

  @spec validate_name(term()) :: :ok | {:error, term()}
  defp validate_name(name) when is_binary(name) do
    if String.trim(name) == "", do: {:error, {:invalid_name, name}}, else: :ok
  end

  defp validate_name(name), do: {:error, {:invalid_name, name}}

  @spec validate_description(term()) :: :ok | {:error, term()}
  defp validate_description(description) when is_binary(description), do: :ok
  defp validate_description(description), do: {:error, {:invalid_description, description}}

  @spec validate_schema(term()) :: :ok | {:error, term()}
  defp validate_schema(schema) when is_map(schema), do: :ok
  defp validate_schema(schema), do: {:error, {:invalid_parameter_schema, schema}}

  @spec validate_callback(term()) :: :ok | {:error, term()}
  defp validate_callback(nil), do: :ok
  defp validate_callback(callback) when is_function(callback, 1), do: :ok
  defp validate_callback(callback), do: {:error, {:invalid_callback, callback}}

  @spec validate_build(term()) :: :ok | {:error, term()}
  defp validate_build(build) when is_function(build, 1), do: :ok
  defp validate_build(build), do: {:error, {:invalid_build, build}}

  @spec validate_category(term()) :: :ok | {:error, term()}
  defp validate_category(category)
       when category in [:filesystem, :git, :lsp, :shell, :memory, :agent, :network, :custom],
       do: :ok

  defp validate_category(category), do: {:error, {:invalid_category, category}}

  @spec validate_approval_level(term()) :: :ok | {:error, term()}
  defp validate_approval_level(level) when level in [:auto, :ask, :deny], do: :ok
  defp validate_approval_level(level), do: {:error, {:invalid_approval_level, level}}

  @spec validate_atom_list(atom(), term()) :: :ok | {:error, term()}
  defp validate_atom_list(_field, values) when is_list(values) do
    if Enum.all?(values, &is_atom/1), do: :ok, else: {:error, {:invalid_atom_list, values}}
  end

  defp validate_atom_list(field, values), do: {:error, {field, values}}

  @spec validate_metadata(term()) :: :ok | {:error, term()}
  defp validate_metadata(metadata) when is_map(metadata), do: :ok
  defp validate_metadata(metadata), do: {:error, {:invalid_metadata, metadata}}

  @spec validate_context_requirements(category(), [capability()], [context_requirement()]) ::
          :ok | {:error, term()}
  defp validate_context_requirements(_category, capabilities, requirements) do
    if Enum.any?(capabilities, &(&1 in @mutating_capabilities)) and
         :tool_context not in requirements do
      {:error, {:missing_context_requirement, :tool_context}}
    else
      :ok
    end
  end
end

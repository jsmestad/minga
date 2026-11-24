defmodule MingaAgent.Tool.Spec do
  @moduledoc """
  Source-owned declaration for an agent tool.

  A spec describes a tool and how to build its executable callback for a session. It does not own session state, credentials, approval decisions, events, or cleanup. Context-sensitive tools declare their requirements and receive a core-built `MingaAgent.Tool.Context` only when the executor has one.
  """

  @typedoc "Source that contributed this tool."
  @type source ::
          :builtin
          | :config
          | {:bundle, :read_only_tools}
          | {:bundle, :lsp_tools}
          | {:bundle, :memory_tools}
          | {:bundle, :introspection_tools}
          | {:extension, atom()}

  @typedoc "Approval level for tool execution."
  @type approval_level :: :auto | :ask | :deny

  @typedoc """
  Effect classification for scheduling.

  `:read_only` tools may execute concurrently. `:mutating` and
  `:approval_required` tools execute sequentially in model order.

  Only an explicit `effect: :read_only` declaration makes a tool concurrent. A tool that declares no effect is classified from its approval level alone and is never read-only, because a capability list does not prove the absence of side effects.
  """
  @type effect :: :read_only | :mutating | :approval_required

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

  @typep argument_validation ::
           {:ok, term()} | {:error, {:invalid_tool_arguments, term()}}

  @typedoc "A tool specification."
  @type t :: %__MODULE__{
          source: source(),
          name: String.t(),
          description: String.t(),
          parameter_schema: map(),
          parameter_validator: JSV.Root.t(),
          build: build_fun(),
          category: category(),
          approval_level: approval_level(),
          effect: effect(),
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

  @enforce_keys [:source, :name, :description, :parameter_schema, :parameter_validator, :build]
  defstruct source: :config,
            name: nil,
            description: nil,
            parameter_schema: %{},
            parameter_validator: nil,
            build: nil,
            category: :custom,
            approval_level: :auto,
            effect: :mutating,
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
    build = resolve_build(Map.get(attrs, :build), callback)
    category = Map.get(attrs, :category, :custom)
    approval_level = Map.get(attrs, :approval_level, :auto)
    capabilities = Map.get(attrs, :capabilities, [])
    context_requirements = Map.get(attrs, :context_requirements, [])
    metadata = Map.get(attrs, :metadata, %{})

    effect = Map.get_lazy(attrs, :effect, fn -> derive_effect(approval_level) end)

    with :ok <- validate_source(source),
         :ok <- validate_name(name),
         :ok <- validate_description(description),
         :ok <- validate_schema(parameter_schema),
         :ok <- validate_callback_declaration(Map.get(attrs, :build), callback),
         :ok <- validate_build(build),
         :ok <- validate_category(category),
         :ok <- validate_approval_level(approval_level),
         :ok <- validate_atom_list(:capabilities, capabilities),
         :ok <- validate_effect(effect, capabilities),
         :ok <- validate_atom_list(:context_requirements, context_requirements),
         :ok <- validate_metadata(metadata),
         :ok <- validate_context_requirements(category, capabilities, context_requirements),
         {:ok, parameter_validator} <- compile_parameter_schema(parameter_schema) do
      {:ok,
       %__MODULE__{
         source: source,
         name: name,
         description: description,
         parameter_schema: parameter_schema,
         parameter_validator: parameter_validator,
         build: build,
         category: category,
         approval_level: approval_level,
         effect: effect,
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

  @doc "Returns true when the spec declares a read-only effect."
  @spec read_only?(t()) :: boolean()
  def read_only?(%__MODULE__{effect: :read_only}), do: true
  def read_only?(%__MODULE__{}), do: false

  @doc "Returns true when the spec declares a sequential effect (mutating or approval-required)."
  @spec sequential?(t()) :: boolean()
  def sequential?(%__MODULE__{effect: :mutating}), do: true
  def sequential?(%__MODULE__{effect: :approval_required}), do: true
  def sequential?(%__MODULE__{}), do: false

  @doc """
  Derives the effect of a spec that declares none.

  Approval-gated tools are `:approval_required`. Every other undeclared tool is `:mutating`: read-only scheduling requires an explicit declaration.
  """
  @spec derive_effect(approval_level()) :: effect()
  def derive_effect(:ask), do: :approval_required
  def derive_effect(:deny), do: :approval_required
  def derive_effect(:auto), do: :mutating

  @doc "Builds an executable callback for the given runtime context."
  @spec build_callback(t(), term()) :: callback()
  def build_callback(%__MODULE__{build: build, name: name, source: source}, context) do
    callback = build.(context)

    Minga.Telemetry.execute(
      [:minga, :agent, :tool, :callback_built],
      %{count: 1},
      %{name: name, source: source}
    )

    callback
  end

  @doc "Validates the canonical declared schema before building any executable callback."
  @spec validate_arguments(t(), map()) :: {:ok, map()} | {:error, term()}
  def validate_arguments(%__MODULE__{parameter_validator: validator} = spec, args)
      when is_map(args) do
    with {:ok, json_args} <- validation_value(args),
         {:ok, _validated} <- JSV.validate(json_args, validator, cast: false) do
      validate_sdk_arguments(spec, args)
    end
  end

  @spec validate_sdk_arguments(t(), map()) :: {:ok, map()} | {:error, term()}
  defp validate_sdk_arguments(%__MODULE__{metadata: %{sdk_input: tool}}, args),
    do: ReqLLM.Tool.validate_input(tool, args)

  defp validate_sdk_arguments(%__MODULE__{}, args), do: {:ok, args}

  @spec compile_parameter_schema(map()) :: {:ok, JSV.Root.t()} | {:error, term()}
  defp compile_parameter_schema(schema) do
    case JSV.build(schema, resolver: [], formats: true) do
      {:ok, validator} -> {:ok, validator}
      {:error, reason} -> {:error, {:invalid_parameter_schema, reason}}
    end
  end

  @spec validation_value(term()) :: argument_validation()
  defp validation_value(%_{}), do: {:error, {:invalid_tool_arguments, :non_json_value}}

  defp validation_value(value) when is_map(value),
    do: Enum.reduce_while(value, {:ok, value}, &validation_entry(&1, &2, value))

  defp validation_value([_ | _] = value), do: validation_list(value)
  defp validation_value([]), do: {:ok, []}

  defp validation_value(value) when is_atom(value) and value not in [true, false, nil],
    do: {:ok, Atom.to_string(value)}

  defp validation_value(value)
       when is_binary(value) or is_number(value) or value in [true, false, nil],
       do: {:ok, value}

  defp validation_value(_value), do: {:error, {:invalid_tool_arguments, :non_json_value}}

  @spec validation_entry({term(), term()}, {:ok, map()}, map()) ::
          {:cont, {:ok, map()}} | {:halt, argument_validation()}
  defp validation_entry({key, value}, {:ok, normalized}, original) do
    with {:ok, json_key} <- validation_key(key, original),
         {:ok, json_value} <- validation_value(value) do
      updated =
        if key === json_key and value === json_value,
          do: normalized,
          else: normalized |> Map.delete(key) |> Map.put(json_key, json_value)

      {:cont, {:ok, updated}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  @spec validation_key(term(), map()) :: argument_validation()
  defp validation_key(key, _original) when is_binary(key), do: {:ok, key}

  defp validation_key(key, original) when is_atom(key) do
    json_key = Atom.to_string(key)

    if Map.has_key?(original, json_key),
      do: {:error, {:invalid_tool_arguments, {:ambiguous_key, json_key}}},
      else: {:ok, json_key}
  end

  defp validation_key(_key, _original), do: {:error, {:invalid_tool_arguments, :non_json_key}}

  @spec validation_list(term()) :: argument_validation()
  defp validation_list([]), do: {:ok, []}

  defp validation_list([head | tail] = original) do
    with {:ok, json_head} <- validation_value(head),
         {:ok, json_tail} <- validation_list(tail) do
      if head === json_head and tail === json_tail,
        do: {:ok, original},
        else: {:ok, [json_head | json_tail]}
    end
  end

  defp validation_list(_value), do: {:error, {:invalid_tool_arguments, :non_json_value}}

  @spec resolve_build(term(), term()) :: build_fun() | nil
  defp resolve_build(nil, callback) when is_function(callback, 1), do: fn _context -> callback end
  defp resolve_build(build, _callback), do: build

  @spec validate_callback_declaration(term(), term()) :: :ok | {:error, term()}
  defp validate_callback_declaration(build, callback)
       when is_function(build, 1) and is_function(callback, 1),
       do: {:error, {:conflicting_execution_declarations, [:build, :callback]}}

  defp validate_callback_declaration(_build, callback), do: validate_callback(callback)

  @spec validate_source(term()) :: :ok | {:error, term()}
  defp validate_source(:builtin), do: :ok
  defp validate_source(:config), do: :ok
  defp validate_source({:bundle, :read_only_tools}), do: :ok
  defp validate_source({:bundle, :lsp_tools}), do: :ok
  defp validate_source({:bundle, :memory_tools}), do: :ok
  defp validate_source({:bundle, :introspection_tools}), do: :ok
  defp validate_source({:bundle, _name} = source), do: {:error, {:invalid_source, source}}
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

  # A read-only declaration that also claims a mutating capability contradicts itself.
  @spec validate_effect(term(), [capability()]) :: :ok | {:error, term()}
  defp validate_effect(:read_only, capabilities) when is_list(capabilities) do
    case Enum.filter(capabilities, &(&1 in @mutating_capabilities)) do
      [] -> :ok
      mutating -> {:error, {:read_only_with_mutating_capabilities, mutating}}
    end
  end

  defp validate_effect(effect, _capabilities) when effect in [:mutating, :approval_required],
    do: :ok

  defp validate_effect(effect, _capabilities), do: {:error, {:invalid_effect, effect}}

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

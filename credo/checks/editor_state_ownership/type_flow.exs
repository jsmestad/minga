defmodule Minga.Credo.EditorStateOwnership.TypeFlow do
  @moduledoc """
  Lexical local type flow for EX9012 receivers and callable values.

  Only whole-value bindings inherit an enclosing struct type. Variables inside
  a struct's fields remain untyped unless their own nested pattern explicitly
  names a struct.
  """

  alias Minga.Credo.EditorStateOwnership.Ownership
  alias Minga.Credo.EditorStateOwnership.Policy
  alias Minga.Credo.EditorStateOwnership.SourceEnvironment

  @enforce_keys [:bindings]
  defstruct bindings: %{}

  @type binding :: %{
          optional(:struct) => String.t(),
          optional(:module) => String.t(),
          optional(:call) => {String.t(), atom(), non_neg_integer()}
        }
  @type t :: %__MODULE__{bindings: %{optional(atom()) => binding()}}

  @doc "Returns an empty lexical flow scope."
  @spec new() :: t()
  def new, do: %__MODULE__{bindings: %{}}

  @doc "Binds explicit whole-struct patterns in function or branch patterns."
  @spec bind_patterns(t(), Macro.t(), SourceEnvironment.t()) :: t()
  def bind_patterns(%__MODULE__{} = flow, patterns, %SourceEnvironment{} = env) do
    patterns
    |> List.wrap()
    |> Enum.reduce(flow, &bind_pattern(&2, &1, env))
  end

  @doc "Updates local bindings after a source-ordered match expression."
  @spec after_match(t(), Macro.t(), Macro.t(), SourceEnvironment.t(), Policy.t()) :: t()
  def after_match(
        %__MODULE__{} = flow,
        left,
        right,
        %SourceEnvironment{} = env,
        %Policy{} = policy
      ) do
    flow = drop_variables(flow, pattern_variables(left))
    binding = expression_binding(right, flow, env, policy)

    flow =
      flow
      |> bind_whole_pattern(left, binding, env)
      |> bind_nested_struct_patterns(left, env)

    case explicit_struct(left, env) do
      nil -> flow
      struct -> bind_whole_pattern(flow, right, %{struct: struct}, env)
    end
  end

  @doc "Returns the ownership attributable to a receiver expression."
  @spec receiver_ownership(Macro.t(), t(), SourceEnvironment.t(), Policy.t()) ::
          Ownership.t() | nil
  def receiver_ownership(
        receiver,
        %__MODULE__{} = flow,
        %SourceEnvironment{} = env,
        %Policy{} = policy
      ) do
    case expression_binding(receiver, flow, env, policy) do
      %{struct: struct} -> Policy.ownership_by_struct(policy, struct)
      _unknown -> Policy.ownership_for_path(policy, field_path(receiver))
    end
  end

  @doc "Returns the inferred binding for one expression."
  @spec expression_binding(Macro.t(), t(), SourceEnvironment.t(), Policy.t()) :: binding() | nil
  def expression_binding(
        {name, _, variable_context},
        %__MODULE__{bindings: bindings},
        %SourceEnvironment{},
        %Policy{}
      )
      when is_atom(name) and is_atom(variable_context) do
    Map.get(bindings, name)
  end

  def expression_binding(
        {:&, _, [{:/, _, [{{:., _, [module_ast, function]}, _, []}, arity]}]},
        %__MODULE__{} = _flow,
        %SourceEnvironment{} = env,
        %Policy{}
      )
      when is_atom(function) and is_integer(arity) do
    case SourceEnvironment.module_name(module_ast, env) do
      nil -> nil
      module -> %{call: {module, function, arity}}
    end
  end

  def expression_binding(
        {:&, _, [{:/, _, [{function, _, variable_context}, arity]}]},
        %__MODULE__{} = _flow,
        %SourceEnvironment{} = env,
        %Policy{}
      )
      when is_atom(function) and is_atom(variable_context) and is_integer(arity) do
    case SourceEnvironment.imported_module(env, function, arity) do
      nil -> nil
      module -> %{call: {module, function, arity}}
    end
  end

  def expression_binding(
        {:__aliases__, _, _} = module_ast,
        %__MODULE__{},
        %SourceEnvironment{} = env,
        %Policy{}
      ) do
    case SourceEnvironment.module_name(module_ast, env) do
      nil -> nil
      module -> %{module: module}
    end
  end

  def expression_binding(
        {:|>, _, [receiver, call]},
        %__MODULE__{} = flow,
        %SourceEnvironment{} = env,
        %Policy{} = policy
      ) do
    if ownership_preserving_pipeline?(call, env),
      do: expression_binding(receiver, flow, env, policy)
  end

  def expression_binding(
        {{:., _, [module_ast, :put]}, _, [receiver | _args]},
        %__MODULE__{} = flow,
        %SourceEnvironment{} = env,
        %Policy{} = policy
      ) do
    if SourceEnvironment.module_name(module_ast, env) == "Map" do
      expression_binding(receiver, flow, env, policy)
    end
  end

  def expression_binding(
        {:put, _, [receiver, _key, _value]},
        %__MODULE__{} = flow,
        %SourceEnvironment{} = env,
        %Policy{} = policy
      ) do
    if SourceEnvironment.imported_module(env, :put, 3) == "Map" do
      expression_binding(receiver, flow, env, policy)
    end
  end

  def expression_binding(ast, %__MODULE__{}, %SourceEnvironment{} = env, %Policy{} = policy) do
    case explicit_struct(ast, env) do
      nil -> policy |> Policy.ownership_for_path(field_path(ast)) |> ownership_binding()
      struct -> %{struct: struct}
    end
  end

  @doc "Returns the field path represented by a dotted receiver expression."
  @spec field_path(Macro.t()) :: [atom()] | nil
  def field_path({{:., _, [base, field]}, _, []}) when is_atom(field) do
    case field_path(base) do
      nil -> [field]
      path -> path ++ [field]
    end
  end

  def field_path({_name, _, variable_context}) when is_atom(variable_context), do: nil
  def field_path(_ast), do: nil

  @doc "Returns a static Access path."
  @spec access_path(Macro.t()) :: [atom()] | nil
  def access_path(list) when is_list(list) do
    list
    |> Enum.map(&access_key/1)
    |> Enum.reduce_while([], fn
      nil, _acc -> {:halt, nil}
      key, acc -> {:cont, [key | acc]}
    end)
    |> case do
      nil -> nil
      reversed -> Enum.reverse(reversed)
    end
  end

  def access_path(_ast), do: nil

  @doc "Drops the final field mutated by put_in."
  @spec drop_updated_field([atom()] | nil) :: [atom()] | nil
  def drop_updated_field(nil), do: nil
  def drop_updated_field([]), do: []
  def drop_updated_field(path), do: Enum.drop(path, -1)

  @doc "Combines a receiver path and a piped static Access path."
  @spec combine_paths([atom()] | nil, [atom()] | nil) :: [atom()] | nil
  def combine_paths(nil, nil), do: nil
  def combine_paths(path, nil), do: path
  def combine_paths(nil, path), do: path
  def combine_paths(left, right), do: left ++ right

  @doc "Returns the canonical longest path declared for an ownership."
  @spec canonical_path(Ownership.t() | nil) :: [atom()] | nil
  def canonical_path(nil), do: nil
  def canonical_path(%Ownership{paths: paths}), do: Enum.max_by(paths, &length/1, fn -> nil end)

  @doc "Returns a variable's callable binding."
  @spec callable(t(), atom()) :: {String.t(), atom(), non_neg_integer()} | nil
  def callable(%__MODULE__{bindings: bindings}, name) do
    case get_in(bindings, [name, :call]) do
      {module, function, arity} -> {module, function, arity}
      _unknown -> nil
    end
  end

  @doc "Returns a variable's module binding."
  @spec bound_module(t(), atom()) :: String.t() | nil
  def bound_module(%__MODULE__{bindings: bindings}, name), do: get_in(bindings, [name, :module])

  @spec bind_pattern(t(), Macro.t(), SourceEnvironment.t()) :: t()
  defp bind_pattern(%__MODULE__{} = flow, {:=, _, [left, right]}, env) do
    flow
    |> bind_whole_pattern(left, struct_binding(right, env), env)
    |> bind_whole_pattern(right, struct_binding(left, env), env)
    |> bind_nested_struct_patterns(left, env)
    |> bind_nested_struct_patterns(right, env)
  end

  defp bind_pattern(%__MODULE__{} = flow, pattern, env) do
    bind_nested_struct_patterns(flow, pattern, env)
  end

  @spec bind_nested_struct_patterns(t(), Macro.t(), SourceEnvironment.t()) :: t()
  defp bind_nested_struct_patterns(
         %__MODULE__{} = flow,
         {:%, _, [_module_ast, {:%{}, _, fields}]},
         env
       ) do
    Enum.reduce(fields, flow, fn
      {_field, nested_pattern}, acc -> bind_nested_struct_patterns(acc, nested_pattern, env)
      _other, acc -> acc
    end)
  end

  defp bind_nested_struct_patterns(%__MODULE__{} = flow, {:=, _, [left, right]}, env) do
    flow
    |> bind_whole_pattern(left, struct_binding(right, env), env)
    |> bind_whole_pattern(right, struct_binding(left, env), env)
    |> bind_nested_struct_patterns(left, env)
    |> bind_nested_struct_patterns(right, env)
  end

  defp bind_nested_struct_patterns(%__MODULE__{} = flow, list, env) when is_list(list) do
    Enum.reduce(list, flow, &bind_nested_struct_patterns(&2, &1, env))
  end

  defp bind_nested_struct_patterns(%__MODULE__{} = flow, tuple, env) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce(flow, &bind_nested_struct_patterns(&2, &1, env))
  end

  defp bind_nested_struct_patterns(%__MODULE__{} = flow, _pattern, _env), do: flow

  @spec bind_whole_pattern(t(), Macro.t(), binding() | nil, SourceEnvironment.t()) :: t()
  defp bind_whole_pattern(%__MODULE__{} = flow, _pattern, nil, _env), do: flow

  defp bind_whole_pattern(%__MODULE__{} = flow, {name, _, variable_context}, binding, _env)
       when is_atom(name) and is_atom(variable_context) and name != :_ do
    %{flow | bindings: Map.put(flow.bindings, name, binding)}
  end

  defp bind_whole_pattern(%__MODULE__{} = flow, {:=, _, [left, right]}, binding, env) do
    flow
    |> bind_whole_pattern(left, binding, env)
    |> bind_whole_pattern(right, binding, env)
  end

  defp bind_whole_pattern(%__MODULE__{} = flow, _pattern, _binding, _env), do: flow

  @spec explicit_struct(Macro.t(), SourceEnvironment.t()) :: String.t() | nil
  defp explicit_struct({:%, _, [module_ast, {:%{}, _, _fields}]}, env) do
    SourceEnvironment.module_name(module_ast, env)
  end

  defp explicit_struct(_ast, _env), do: nil

  @spec struct_binding(Macro.t(), SourceEnvironment.t()) :: binding() | nil
  defp struct_binding(ast, env) do
    case explicit_struct(ast, env) do
      nil -> nil
      struct -> %{struct: struct}
    end
  end

  @spec ownership_binding(Ownership.t() | nil) :: binding() | nil
  defp ownership_binding(nil), do: nil
  defp ownership_binding(%Ownership{struct: struct}), do: %{struct: struct}

  @spec ownership_preserving_pipeline?(Macro.t(), SourceEnvironment.t()) :: boolean()
  defp ownership_preserving_pipeline?({{:., _, [module_ast, :put]}, _, args}, env)
       when is_list(args) do
    SourceEnvironment.module_name(module_ast, env) == "Map"
  end

  defp ownership_preserving_pipeline?({name, _, args}, env)
       when is_atom(name) and is_list(args) do
    name in [:put_in, :update_in] or
      (name == :put and SourceEnvironment.imported_module(env, name, length(args) + 1) == "Map")
  end

  defp ownership_preserving_pipeline?(_call, _env), do: false

  @spec access_key(Macro.t()) :: atom() | nil
  defp access_key(key) when is_atom(key), do: key

  defp access_key({{:., _, [{:__aliases__, _, [:Access]}, function]}, _, [key]})
       when function in [:key, :key!] and is_atom(key),
       do: key

  defp access_key(_ast), do: nil

  @spec drop_variables(t(), [atom()]) :: t()
  defp drop_variables(%__MODULE__{} = flow, names) do
    %{flow | bindings: Map.drop(flow.bindings, names)}
  end

  @spec pattern_variables(Macro.t()) :: [atom()]
  defp pattern_variables(pattern) do
    {_pattern, variables} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {name, _, variable_context} = node, acc
        when is_atom(name) and is_atom(variable_context) and name != :_ ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(variables)
  end
end

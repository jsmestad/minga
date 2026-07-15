defmodule Minga.Credo.EditorStateOwnership.PurityRule do
  @moduledoc """
  Pure-owner external-boundary classification for EX9012.

  The broad MingaAgent namespace is effectful by default. Only exact value and
  contract modules declared by policy are exempt. Local delegation summaries
  are built with lexical, source-ordered alias and import environments.
  """

  alias Minga.Credo.EditorStateOwnership.Ownership
  alias Minga.Credo.EditorStateOwnership.Policy
  alias Minga.Credo.EditorStateOwnership.SourceEnvironment

  @local_effect_calls ~w(send spawn spawn_link spawn_monitor)a
  @erlang_effect_calls ~w(send send_after start_timer cancel_timer monitor demonitor spawn spawn_link spawn_monitor)a
  @ast_forms ~w(__block__ __aliases__ alias import require use def defp defmacro defmacrop defmodule @ = |> fn -> when case if unless receive try with for)a

  @typedoc "A pure-boundary finding emitted to the EX9012 reporter."
  @type finding :: %{
          violation: String.t(),
          target: String.t(),
          receiver: String.t(),
          ownership: Ownership.t(),
          module: String.t() | nil,
          function: String.t() | nil,
          line: pos_integer()
        }

  @type boundary :: {String.t(), atom(), non_neg_integer()}
  @type local_boundaries :: %{{atom(), non_neg_integer()} => boundary()}
  @typep summary :: %{boundary: boundary() | nil, calls: MapSet.t({atom(), non_neg_integer()})}

  @doc "Checks one resolved remote or imported call from the current source position."
  @spec check_call(
          String.t() | nil,
          atom(),
          non_neg_integer(),
          Macro.t(),
          keyword(),
          SourceEnvironment.t(),
          Policy.t()
        ) :: [finding()]
  def check_call(nil, _function, _arity, _ast, _meta, _env, _policy), do: []

  def check_call(module, function, arity, ast, meta, env, policy) do
    ownership = Policy.ownership_for_owner(policy, env.module)

    if Policy.pure_owner?(policy, env.module) and prohibited_call?(module, function, policy) and
         not Policy.value_module?(policy, module) and ownership do
      [finding(module, function, arity, ast, meta, env, ownership)]
    else
      []
    end
  end

  @doc "Checks a local call whose implementation resolves to an external boundary."
  @spec check_local(
          atom(),
          non_neg_integer(),
          Macro.t(),
          keyword(),
          SourceEnvironment.t(),
          Policy.t(),
          local_boundaries()
        ) :: [finding()]
  def check_local(name, arity, ast, meta, env, policy, boundaries) do
    case Map.get(boundaries, {name, arity}) do
      {module, function, target_arity} ->
        check_call(module, function, target_arity, ast, meta, env, policy)

      nil ->
        []
    end
  end

  @doc "Returns whether a resolved call crosses a prohibited value-owner boundary."
  @spec prohibited_call?(String.t(), atom(), Policy.t()) :: boolean()
  def prohibited_call?(":file", :format_error, %Policy{}), do: false

  def prohibited_call?("Kernel", function, %Policy{}) when function in @local_effect_calls,
    do: true

  def prohibited_call?(":erlang", function, %Policy{}) when function in @erlang_effect_calls,
    do: true

  def prohibited_call?(module, _function, %Policy{} = policy) do
    MapSet.member?(policy.process_modules, module) or
      Enum.any?(policy.boundary_prefixes, fn prefix ->
        module == prefix or String.starts_with?(module, prefix <> ".")
      end) or boundary_segment?(module, policy.boundary_segments)
  end

  @doc "Builds local delegation summaries for one module body without crossing nested modules."
  @spec local_boundaries(Macro.t(), SourceEnvironment.t(), Policy.t()) :: local_boundaries()
  def local_boundaries(body, %SourceEnvironment{} = env, %Policy{} = policy) do
    {definitions, _env} = collect_definitions(forms(body), env, %{}, policy)

    direct =
      Map.new(definitions, fn {identity, %{body: function_body, env: function_env}} ->
        {boundary, calls, _env} = summarize(function_body, function_env, policy)
        {identity, %{boundary: boundary, calls: calls}}
      end)

    resolve_boundaries(direct)
  end

  @spec finding(
          String.t(),
          atom(),
          non_neg_integer(),
          Macro.t(),
          keyword(),
          SourceEnvironment.t(),
          Ownership.t()
        ) :: finding()
  defp finding(module, function, _arity, ast, meta, env, ownership) do
    %{
      violation: "pure_call",
      target: "#{module}.#{function}",
      receiver: Macro.to_string(ast),
      ownership: ownership,
      module: env.module,
      function: env.function,
      line: meta[:line] || 1
    }
  end

  @spec boundary_segment?(String.t(), MapSet.t(String.t())) :: boolean()
  defp boundary_segment?(module, segments) do
    module |> String.split(".") |> Enum.any?(&MapSet.member?(segments, &1))
  end

  @spec forms(Macro.t()) :: [Macro.t()]
  defp forms({:__block__, _, forms}) when is_list(forms), do: forms
  defp forms(ast), do: [ast]

  @spec collect_definitions([Macro.t()], SourceEnvironment.t(), map(), Policy.t()) ::
          {map(), SourceEnvironment.t()}
  defp collect_definitions([], env, definitions, _policy), do: {definitions, env}

  defp collect_definitions([form | rest], env, definitions, policy) do
    if SourceEnvironment.directive?(form) do
      collect_definitions(rest, SourceEnvironment.apply_directive(env, form), definitions, policy)
    else
      definitions = collect_definition(form, env, definitions)
      collect_definitions(rest, env, definitions, policy)
    end
  end

  @spec collect_definition(Macro.t(), SourceEnvironment.t(), map()) :: map()
  defp collect_definition({kind, _, [head, blocks]}, env, definitions)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(blocks) do
    case function_identity(head) do
      {name, arity, _args} ->
        function_env = SourceEnvironment.enter_function(env, "#{name}/#{arity}")
        Map.put(definitions, {name, arity}, %{body: Keyword.values(blocks), env: function_env})

      nil ->
        definitions
    end
  end

  defp collect_definition(_form, _env, definitions), do: definitions

  @spec summarize(Macro.t(), SourceEnvironment.t(), Policy.t()) ::
          {boundary() | nil, MapSet.t({atom(), non_neg_integer()}), SourceEnvironment.t()}
  defp summarize(ast, env, policy), do: summarize(ast, env, policy, nil, MapSet.new())

  @spec summarize(
          Macro.t(),
          SourceEnvironment.t(),
          Policy.t(),
          boundary() | nil,
          MapSet.t({atom(), non_neg_integer()})
        ) :: {boundary() | nil, MapSet.t({atom(), non_neg_integer()}), SourceEnvironment.t()}
  defp summarize({:__block__, _, body}, env, policy, boundary, calls) when is_list(body) do
    summarize_sequence(body, env, policy, boundary, calls)
  end

  defp summarize({kind, _, _args}, env, _policy, boundary, calls)
       when kind in [:defmodule, :def, :defp, :defmacro, :defmacrop],
       do: {boundary, calls, env}

  defp summarize({kind, _, _args} = directive, env, _policy, boundary, calls)
       when kind in [:alias, :import] do
    {boundary, calls, SourceEnvironment.apply_directive(env, directive)}
  end

  defp summarize({:->, _, [_patterns, body]}, env, policy, boundary, calls) do
    {branch_boundary, branch_calls, _branch_env} = summarize(body, env, policy, boundary, calls)
    {branch_boundary, branch_calls, env}
  end

  defp summarize({{:., _, [module_ast, function]}, _, args} = ast, env, policy, boundary, calls)
       when is_atom(function) and is_list(args) do
    module = SourceEnvironment.module_name(module_ast, env)
    boundary = boundary || call_boundary(module, function, length(args), policy)
    summarize_children(ast, env, policy, boundary, calls)
  end

  defp summarize({name, _, args} = ast, env, policy, boundary, calls)
       when is_atom(name) and is_list(args) do
    module = SourceEnvironment.imported_module(env, name, length(args))

    boundary =
      boundary ||
        call_boundary(module, name, length(args), policy) ||
        local_effect_boundary(name, length(args), policy)

    calls =
      if is_nil(module) and name not in @ast_forms,
        do: MapSet.put(calls, {name, length(args)}),
        else: calls

    summarize_children(ast, env, policy, boundary, calls)
  end

  defp summarize(ast, env, policy, boundary, calls) do
    summarize_children(ast, env, policy, boundary, calls)
  end

  @spec summarize_children(
          Macro.t(),
          SourceEnvironment.t(),
          Policy.t(),
          boundary() | nil,
          MapSet.t({atom(), non_neg_integer()})
        ) :: {boundary() | nil, MapSet.t({atom(), non_neg_integer()}), SourceEnvironment.t()}
  defp summarize_children(tuple, env, policy, boundary, calls) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> summarize_sequence(env, policy, boundary, calls)
  end

  defp summarize_children(list, env, policy, boundary, calls) when is_list(list) do
    summarize_sequence(list, env, policy, boundary, calls)
  end

  defp summarize_children(_ast, env, _policy, boundary, calls), do: {boundary, calls, env}

  @spec summarize_sequence(
          [Macro.t()],
          SourceEnvironment.t(),
          Policy.t(),
          boundary() | nil,
          MapSet.t({atom(), non_neg_integer()})
        ) :: {boundary() | nil, MapSet.t({atom(), non_neg_integer()}), SourceEnvironment.t()}
  defp summarize_sequence([], env, _policy, boundary, calls), do: {boundary, calls, env}

  defp summarize_sequence([ast | rest], env, policy, boundary, calls) do
    {boundary, calls, env} = summarize(ast, env, policy, boundary, calls)
    summarize_sequence(rest, env, policy, boundary, calls)
  end

  @spec call_boundary(String.t() | nil, atom(), non_neg_integer(), Policy.t()) :: boundary() | nil
  defp call_boundary(nil, _function, _arity, _policy), do: nil

  defp call_boundary(module, function, arity, policy) do
    if prohibited_call?(module, function, policy) and not Policy.value_module?(policy, module),
      do: {module, function, arity}
  end

  @spec local_effect_boundary(atom(), non_neg_integer(), Policy.t()) :: boundary() | nil
  defp local_effect_boundary(name, arity, policy) do
    call_boundary("Kernel", name, arity, policy)
  end

  @spec resolve_boundaries(%{{atom(), non_neg_integer()} => summary()}) :: local_boundaries()
  defp resolve_boundaries(summaries) do
    resolved =
      Map.new(summaries, fn {identity, summary} ->
        {identity, summary.boundary}
      end)

    resolved
    |> propagate_boundaries(summaries, MapSet.new(Map.keys(summaries)))
    |> Map.reject(fn {_identity, boundary} -> is_nil(boundary) end)
  end

  @spec propagate_boundaries(map(), map(), MapSet.t()) :: map()
  defp propagate_boundaries(resolved, summaries, unresolved) do
    {resolved, changed?} =
      Enum.reduce(unresolved, {resolved, false}, fn identity, {acc, changed?} ->
        if Map.get(acc, identity) do
          {acc, changed?}
        else
          boundary =
            summaries
            |> Map.fetch!(identity)
            |> Map.fetch!(:calls)
            |> Enum.find_value(&Map.get(acc, &1))

          {Map.put(acc, identity, boundary), changed? or not is_nil(boundary)}
        end
      end)

    remaining = MapSet.filter(unresolved, &is_nil(Map.get(resolved, &1)))

    if changed? and MapSet.size(remaining) > 0,
      do: propagate_boundaries(resolved, summaries, remaining),
      else: resolved
  end

  @spec function_identity(Macro.t()) :: {atom(), non_neg_integer(), [Macro.t()]} | nil
  defp function_identity({:when, _, [head | _guards]}), do: function_identity(head)
  defp function_identity({name, _, nil}) when is_atom(name), do: {name, 0, []}

  defp function_identity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), args}

  defp function_identity(_head), do: nil
end

defmodule Minga.Credo.EditorStateOwnership.Analysis do
  @moduledoc """
  Source-ordered traversal kernel for EX9012.

  The kernel owns lexical scope and AST order only. Source environments, type
  flow, direct-write classification, generic API detection, and purity checks
  live in focused modules so future ownership rules remain additive.
  """

  alias Minga.Credo.EditorStateOwnership.DirectWriteRule
  alias Minga.Credo.EditorStateOwnership.GenericAPIRule
  alias Minga.Credo.EditorStateOwnership.Policy
  alias Minga.Credo.EditorStateOwnership.PurityRule
  alias Minga.Credo.EditorStateOwnership.SourceEnvironment
  alias Minga.Credo.EditorStateOwnership.TypeFlow

  @local_effect_calls ~w(send spawn spawn_link spawn_monitor)a

  @typedoc "A source location and ownership violation found during traversal."
  @type finding :: DirectWriteRule.finding() | GenericAPIRule.finding() | PurityRule.finding()

  @typep context :: %{
           env: SourceEnvironment.t(),
           flow: TypeFlow.t(),
           local_boundaries: PurityRule.local_boundaries()
         }

  @doc "Returns the first module declared by a quoted source tree."
  @spec source_module(Macro.t()) :: String.t() | nil
  def source_module(ast), do: SourceEnvironment.source_module(ast)

  @doc "Analyzes one quoted Elixir source tree under a validated policy."
  @spec analyze(Macro.t(), Policy.t()) :: [finding()]
  def analyze(ast, %Policy{} = policy) do
    context = %{env: SourceEnvironment.new(), flow: TypeFlow.new(), local_boundaries: %{}}
    {findings, _context} = scan(ast, context, policy)
    findings
  end

  @spec scan(Macro.t(), context(), Policy.t()) :: {[finding()], context()}
  defp scan({:__block__, _, forms}, context, policy) when is_list(forms) do
    scan_sequence(forms, context, policy)
  end

  defp scan({:defmodule, _meta, [module_ast, blocks]}, context, policy)
       when is_list(blocks) do
    case SourceEnvironment.declared_module(module_ast, context.env) do
      nil ->
        {[], context}

      module ->
        module_env = SourceEnvironment.enter_module(context.env, module)
        body = Keyword.get(blocks, :do)
        boundaries = PurityRule.local_boundaries(body, module_env, policy)

        module_context = %{
          env: module_env,
          flow: TypeFlow.new(),
          local_boundaries: boundaries
        }

        {issues, _module_context} = scan(body, module_context, policy)
        {issues, context}
    end
  end

  defp scan({kind, meta, [head, blocks]} = ast, context, policy)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(blocks) do
    case function_identity(head) do
      nil ->
        scan_isolated_children(ast, context, policy)

      {name, arity, args} ->
        function_env = SourceEnvironment.enter_function(context.env, "#{name}/#{arity}")
        function_flow = TypeFlow.bind_patterns(TypeFlow.new(), args, function_env)

        function_context = %{
          context
          | env: function_env,
            flow: function_flow
        }

        body = Keyword.values(blocks)

        generic_issues =
          GenericAPIRule.check(kind, name, args, head, body, meta, function_env, policy)

        {body_issues, _function_context} = scan_sequence(body, function_context, policy)
        {generic_issues ++ body_issues, context}
    end
  end

  defp scan({kind, _, _args} = directive, context, _policy) when kind in [:alias, :import] do
    {[], %{context | env: SourceEnvironment.apply_directive(context.env, directive)}}
  end

  defp scan({:@, _meta, _args}, context, _policy), do: {[], context}
  defp scan({:&, _meta, _args}, context, _policy), do: {[], context}

  defp scan({:=, _, [left, right]}, context, policy) do
    {issues, _right_context} = scan(right, context, policy)
    flow = TypeFlow.after_match(context.flow, left, right, context.env, policy)
    {issues, %{context | flow: flow}}
  end

  defp scan({:->, _, [patterns, body]}, context, policy) do
    branch_flow = TypeFlow.bind_patterns(context.flow, patterns, context.env)
    branch_context = %{context | flow: branch_flow}
    {issues, _branch_context} = scan(body, branch_context, policy)
    {issues, context}
  end

  defp scan({:fn, _, clauses}, context, policy) when is_list(clauses) do
    {scan_isolated_list(clauses, context, policy), context}
  end

  defp scan({:case, _, [subject, blocks]}, context, policy) when is_list(blocks) do
    {subject_issues, _subject_context} = scan(subject, context, policy)
    clause_issues = scan_isolated_list(Keyword.get(blocks, :do, []), context, policy)
    {subject_issues ++ clause_issues, context}
  end

  defp scan({kind, _, [condition, blocks]}, context, policy)
       when kind in [:if, :unless] and is_list(blocks) do
    {condition_issues, condition_context} = scan(condition, context, policy)
    branch_issues = scan_isolated_list(Keyword.values(blocks), condition_context, policy)
    {condition_issues ++ branch_issues, condition_context}
  end

  defp scan({:|>, meta, [receiver, call]}, context, policy) do
    {call_issues, call_children} = pipeline_issues(receiver, call, meta, context, policy)
    {receiver_issues, _receiver_context} = scan(receiver, context, policy)
    child_issues = scan_isolated_list(List.wrap(call_children), context, policy)
    {call_issues ++ receiver_issues ++ child_issues, context}
  end

  defp scan(
         {:%, meta, [module_ast, {:%{}, _, [{:|, _, [receiver, updates]}]}]},
         context,
         policy
       ) do
    struct = SourceEnvironment.module_name(module_ast, context.env)
    ownership = Policy.ownership_by_struct(policy, struct)

    issues =
      DirectWriteRule.check_update(
        ownership,
        receiver,
        updates,
        meta,
        context.flow,
        context.env,
        policy
      )

    {child_issues, _context} = scan_isolated_children({receiver, updates}, context, policy)
    {issues ++ child_issues, context}
  end

  defp scan({:%{}, meta, [{:|, _, [receiver, updates]}]}, context, policy) do
    ownership = TypeFlow.receiver_ownership(receiver, context.flow, context.env, policy)

    issues =
      DirectWriteRule.check_update(
        ownership,
        receiver,
        updates,
        meta,
        context.flow,
        context.env,
        policy
      )

    {child_issues, _context} = scan_isolated_children({receiver, updates}, context, policy)
    {issues ++ child_issues, context}
  end

  defp scan({name, meta, args} = ast, context, policy)
       when name in [:put_in, :update_in] and is_list(args) do
    issues = DirectWriteRule.check_access(name, args, meta, context.flow, context.env, policy)
    {child_issues, _context} = scan_isolated_children(ast, context, policy)
    {issues ++ child_issues, context}
  end

  defp scan({{:., _, [callable]}, meta, args} = ast, context, policy) when is_list(args) do
    issues =
      case TypeFlow.expression_binding(callable, context.flow, context.env, policy) do
        %{call: {module, function, arity}} when arity == length(args) ->
          PurityRule.check_call(module, function, arity, ast, meta, context.env, policy)

        _unknown ->
          []
      end

    {child_issues, _context} = scan_isolated_children(ast, context, policy)
    {issues ++ child_issues, context}
  end

  defp scan({{:., _, [module_ast, function]}, meta, args} = ast, context, policy)
       when is_atom(function) and is_list(args) do
    module = resolved_call_module(module_ast, context)

    issues =
      if module == "Map" and function == :put and length(args) == 3 do
        receiver = List.first(args)
        ownership = TypeFlow.receiver_ownership(receiver, context.flow, context.env, policy)
        DirectWriteRule.check(ownership, receiver, meta, context.env)
      else
        PurityRule.check_call(module, function, length(args), ast, meta, context.env, policy)
      end

    {child_issues, _context} = scan_isolated_children(ast, context, policy)
    {issues ++ child_issues, context}
  end

  defp scan({name, meta, args} = ast, context, policy)
       when name in @local_effect_calls and is_list(args) do
    issues = PurityRule.check_call("Kernel", name, length(args), ast, meta, context.env, policy)
    {child_issues, _context} = scan_isolated_children(ast, context, policy)
    {issues ++ child_issues, context}
  end

  defp scan({name, meta, args} = ast, context, policy)
       when is_atom(name) and is_list(args) do
    module = SourceEnvironment.imported_module(context.env, name, length(args))

    imported_issues =
      if module == "Map" and name == :put and length(args) == 3 do
        receiver = List.first(args)
        ownership = TypeFlow.receiver_ownership(receiver, context.flow, context.env, policy)
        DirectWriteRule.check(ownership, receiver, meta, context.env)
      else
        PurityRule.check_call(module, name, length(args), ast, meta, context.env, policy)
      end

    local_issues =
      if is_nil(module) do
        PurityRule.check_local(
          name,
          length(args),
          ast,
          meta,
          context.env,
          policy,
          context.local_boundaries
        )
      else
        []
      end

    {child_issues, _context} = scan_isolated_children(ast, context, policy)
    {imported_issues ++ local_issues ++ child_issues, context}
  end

  defp scan(ast, context, policy), do: scan_isolated_children(ast, context, policy)

  @spec pipeline_issues(Macro.t(), Macro.t(), keyword(), context(), Policy.t()) ::
          {[finding()], [Macro.t()]}
  defp pipeline_issues(receiver, call, pipe_meta, context, policy) do
    case pipeline_target(call, context) do
      {:remote, "Map", :put, args, call_meta} ->
        ownership = TypeFlow.receiver_ownership(receiver, context.flow, context.env, policy)
        {DirectWriteRule.check(ownership, receiver, call_meta || pipe_meta, context.env), args}

      {:local, name, args, call_meta} when name in [:put_in, :update_in] ->
        issues =
          DirectWriteRule.check_piped_access(
            name,
            receiver,
            args,
            call_meta || pipe_meta,
            context.flow,
            context.env,
            policy
          )

        {issues, args}

      {:remote, module, function, args, call_meta} ->
        meta = call_meta || pipe_meta
        call_ast = {{:., [], [module_ast(module), function]}, meta, [receiver | args]}

        issues =
          PurityRule.check_call(
            module,
            function,
            length(args) + 1,
            call_ast,
            meta,
            context.env,
            policy
          )

        {issues, args}

      {:local, name, args, call_meta} ->
        arity = length(args) + 1
        meta = call_meta || pipe_meta
        module = SourceEnvironment.imported_module(context.env, name, arity)
        call_ast = {name, meta, [receiver | args]}

        issues =
          if module == "Map" and name == :put and arity == 3 do
            ownership = TypeFlow.receiver_ownership(receiver, context.flow, context.env, policy)
            DirectWriteRule.check(ownership, receiver, meta, context.env)
          else
            PurityRule.check_call(module, name, arity, call_ast, meta, context.env, policy) ++
              if(is_nil(module),
                do:
                  PurityRule.check_local(
                    name,
                    arity,
                    call_ast,
                    meta,
                    context.env,
                    policy,
                    context.local_boundaries
                  ),
                else: []
              )
          end

        {issues, args}

      :unknown ->
        {[], [call]}
    end
  end

  @spec pipeline_target(Macro.t(), context()) ::
          {:remote, String.t(), atom(), [Macro.t()], keyword()}
          | {:local, atom(), [Macro.t()], keyword()}
          | :unknown
  defp pipeline_target({{:., _, [module_ast, function]}, meta, args}, context)
       when is_atom(function) and is_list(args) do
    case resolved_call_module(module_ast, context) do
      nil -> :unknown
      module -> {:remote, module, function, args, meta}
    end
  end

  defp pipeline_target({name, meta, args}, _context) when is_atom(name) and is_list(args),
    do: {:local, name, args, meta}

  defp pipeline_target(_call, _context), do: :unknown

  @spec resolved_call_module(Macro.t(), context()) :: String.t() | nil
  defp resolved_call_module({name, _, variable_context} = module_ast, context)
       when is_atom(name) and is_atom(variable_context) do
    TypeFlow.bound_module(context.flow, name) ||
      SourceEnvironment.module_name(module_ast, context.env)
  end

  defp resolved_call_module(module_ast, context) do
    SourceEnvironment.module_name(module_ast, context.env)
  end

  @spec scan_sequence([Macro.t()], context(), Policy.t()) :: {[finding()], context()}
  defp scan_sequence([], context, _policy), do: {[], context}

  defp scan_sequence([ast | rest], context, policy) do
    {issues, context} = scan(ast, context, policy)
    {rest_issues, context} = scan_sequence(rest, context, policy)
    {issues ++ rest_issues, context}
  end

  @spec scan_isolated_list([Macro.t()], context(), Policy.t()) :: [finding()]
  defp scan_isolated_list(list, context, policy) do
    Enum.flat_map(list, fn ast ->
      {issues, _child_context} = scan(ast, context, policy)
      issues
    end)
  end

  @spec scan_isolated_children(Macro.t(), context(), Policy.t()) :: {[finding()], context()}
  defp scan_isolated_children(tuple, context, policy) when is_tuple(tuple) do
    issues = tuple |> Tuple.to_list() |> scan_isolated_list(context, policy)
    {issues, context}
  end

  defp scan_isolated_children(list, context, policy) when is_list(list) do
    {scan_isolated_list(list, context, policy), context}
  end

  defp scan_isolated_children(_ast, context, _policy), do: {[], context}

  @spec function_identity(Macro.t()) :: {atom(), non_neg_integer(), [Macro.t()]} | nil
  defp function_identity({:when, _, [head | _guards]}), do: function_identity(head)
  defp function_identity({name, _, nil}) when is_atom(name), do: {name, 0, []}

  defp function_identity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), args}

  defp function_identity(_head), do: nil

  @spec module_ast(String.t()) :: Macro.t()
  defp module_ast(module) do
    module |> String.split(".") |> Enum.map(&String.to_atom/1) |> then(&{:__aliases__, [], &1})
  end
end

defmodule Minga.Credo.EditorStateOwnership.GenericAPIRule do
  @moduledoc """
  Detects public owner APIs that expose arbitrary callbacks or dynamic keys.

  Focused domain transitions remain additive; this rule rejects only APIs whose
  body gives callers generic mutation authority over an owned value.
  """

  alias Minga.Credo.EditorStateOwnership.Ownership
  alias Minga.Credo.EditorStateOwnership.Policy
  alias Minga.Credo.EditorStateOwnership.SourceEnvironment

  @dynamic_key_functions ~w(
    fetch fetch! get get_lazy get_and_update get_and_update! has_key? pop put put_new put_new_lazy
    replace replace! update update!
  )a

  @typedoc "A generic-API finding emitted to the EX9012 reporter."
  @type finding :: %{
          violation: String.t(),
          target: String.t(),
          receiver: String.t(),
          ownership: Ownership.t(),
          module: String.t() | nil,
          function: String.t() | nil,
          line: pos_integer()
        }

  @doc "Checks one function definition against its current owner contract."
  @spec check(
          atom(),
          atom(),
          [Macro.t()],
          Macro.t(),
          Macro.t(),
          keyword(),
          SourceEnvironment.t(),
          Policy.t()
        ) :: [finding()]
  def check(kind, _name, _args, _head, _body, _meta, _env, _policy)
      when kind in [:defp, :defmacrop],
      do: []

  def check(_kind, name, args, head, body, meta, env, policy) do
    ownership = Policy.ownership_for_owner(policy, env.module)

    if ownership && ownership.generic_api? && generic_api?(args, body, env) do
      target = "#{env.module}.#{name}/#{length(args)}"

      [
        %{
          violation: "generic_api",
          target: target,
          receiver: Macro.to_string(head),
          ownership: ownership,
          module: env.module,
          function: env.function,
          line: meta[:line] || 1
        }
      ]
    else
      []
    end
  end

  @spec generic_api?([Macro.t()], Macro.t(), SourceEnvironment.t()) :: boolean()
  defp generic_api?(args, body, env) do
    argument_names = args |> Enum.map(&argument_name/1) |> Enum.reject(&is_nil/1)

    (length(args) >= 2 and invokes_argument?(body, argument_names)) or
      (length(argument_names) >= 2 and uses_argument_as_dynamic_key?(body, argument_names, env))
  end

  @spec argument_name(Macro.t()) :: atom() | nil
  defp argument_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp argument_name({:\\, _, [arg, _default]}), do: argument_name(arg)
  defp argument_name(_arg), do: nil

  @spec invokes_argument?(Macro.t(), [atom()]) :: boolean()
  defp invokes_argument?(ast, argument_names) do
    ast_contains?(ast, fn
      {{:., _, [{name, _, variable_context}]}, _, args}
      when is_atom(name) and is_atom(variable_context) and is_list(args) ->
        name in argument_names

      _ast ->
        false
    end)
  end

  @spec uses_argument_as_dynamic_key?(Macro.t(), [atom()], SourceEnvironment.t()) :: boolean()
  defp uses_argument_as_dynamic_key?(ast, argument_names, env) do
    ast_contains?(ast, fn
      {{:., _, [module_ast, function]}, _, args}
      when function in @dynamic_key_functions and is_list(args) ->
        SourceEnvironment.module_name(module_ast, env) in ["Map", "Access"] and
          argument_name(Enum.at(args, 0)) in argument_names and
          argument_name(Enum.at(args, 1)) in argument_names

      _ast ->
        false
    end)
  end

  @spec ast_contains?(Macro.t(), (Macro.t() -> boolean())) :: boolean()
  defp ast_contains?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or predicate.(node)}
      end)

    found?
  end
end

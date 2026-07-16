defmodule Minga.Extension.SdkContractTest do
  use ExUnit.Case, async: true

  @dsl_pairs [
    {"lib/minga/extension.ex", "sdk/lib/minga/extension.ex"},
    {"lib/minga/extension/editor.ex", "sdk/lib/minga/extension/editor.ex"},
    {"lib/minga/extension/agent.ex", "sdk/lib/minga/extension/agent.ex"},
    {"lib/minga/extension/macros.ex", "sdk/lib/minga/extension/macros.ex"}
  ]

  test "runtime and SDK declaration DSLs have the same source contract" do
    Enum.each(@dsl_pairs, fn {runtime, sdk} ->
      assert normalized_ast(runtime) == normalized_ast(sdk),
             "#{sdk} must mirror the declaration contract in #{runtime}"
    end)
  end

  test "runtime and SDK callback families cannot drift" do
    runtime_extension = "lib/minga/extension.ex"
    runtime_handler = "lib/minga_editor/extension/event_handler.ex"
    sdk_handler = "sdk/lib/minga_editor/extension/event_handler.ex"

    expected_families = named_union_literals(runtime_extension, :editor_event_family)

    assert named_union_literals(runtime_handler, :event_kind) == expected_families
    assert named_union_literals(sdk_handler, :event_kind) == expected_families
    assert callback_signatures(runtime_handler) == callback_signatures(sdk_handler)
  end

  @spec normalized_ast(String.t()) :: String.t()
  defp normalized_ast(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path)
    |> Macro.to_string()
  end

  @spec callback_signatures(String.t()) :: [{atom(), non_neg_integer()}]
  defp callback_signatures(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, signatures} =
      Macro.prewalk(ast, [], fn
        {:@, _meta, [{:callback, _callback_meta, [{:"::", _spec_meta, [head, _result]}]}]} = node,
        acc ->
          {node, [callable_signature(head) | acc]}

        node, acc ->
          {node, acc}
      end)

    signatures |> Enum.reverse() |> Enum.sort()
  end

  @spec named_union_literals(String.t(), atom()) :: [atom()]
  defp named_union_literals(path, type_name) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, matches} =
      Macro.prewalk(ast, [], fn
        {:@, _meta,
         [
           {:type, _type_meta,
            [{:"::", _spec_meta, [{^type_name, _name_meta, _arguments}, union]}]}
         ]} = node,
        acc ->
          {node, [union_literals(union) | acc]}

        node, acc ->
          {node, acc}
      end)

    case matches do
      [literals] -> Enum.sort(literals)
      _ -> flunk("expected one @type #{type_name} in #{path}")
    end
  end

  @spec callable_signature(Macro.t()) :: {atom(), non_neg_integer()}
  defp callable_signature({:when, _meta, [head | _guards]}), do: callable_signature(head)

  defp callable_signature({name, _meta, arguments}) when is_atom(name) and is_list(arguments),
    do: {name, length(arguments)}

  defp callable_signature({name, _meta, nil}) when is_atom(name), do: {name, 0}

  @spec union_literals(Macro.t()) :: [atom()]
  defp union_literals({:|, _meta, [left, right]}),
    do: union_literals(left) ++ union_literals(right)

  defp union_literals(literal) when is_atom(literal), do: [literal]
  defp union_literals(other), do: flunk("expected an atom union, got: #{Macro.to_string(other)}")
end

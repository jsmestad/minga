defmodule Minga.Extension.SdkContractTest do
  use ExUnit.Case, async: true

  test "runtime and SDK callback families cannot drift" do
    declaration = "sdk/lib/declarations/minga/extension.ex"
    runtime_handler = "lib/minga_editor/extension/event_handler.ex"
    sdk_handler = "sdk/lib/minga_editor/extension/event_handler.ex"

    expected_families = named_union_literals(declaration, :editor_event_family)

    assert named_union_literals(runtime_handler, :event_kind) == expected_families
    assert named_union_literals(sdk_handler, :event_kind) == expected_families
    assert callback_signatures(runtime_handler) == callback_signatures(sdk_handler)
  end

  test "runtime and SDK model route contracts cannot drift" do
    assert callback_signatures("lib/minga_agent/inference_route.ex") ==
             callback_signatures("sdk/lib/minga_agent/inference_route.ex")

    for value <-
          ~w(model conversation_ref spec status reporter credential request response message tool_call tool_declaration options usage plan_window setup_action) do
      runtime = "lib/minga_agent/inference_route/#{value}.ex"
      sdk = "sdk/lib/minga_agent/inference_route/#{value}.ex"
      assert struct_fields(runtime) == struct_fields(sdk), "#{value} fields drifted"
    end

    for {value, type} <- [{"message", :role}, {"plan_window", :status}] do
      assert named_union_literals("lib/minga_agent/inference_route/#{value}.ex", type) ==
               named_union_literals("sdk/lib/minga_agent/inference_route/#{value}.ex", type)
    end

    for {value, type} <- [{"message", :part}, {"event", :t}, {"event", :finish_reason}] do
      assert type_source("lib/minga_agent/inference_route/#{value}.ex", type) ==
               type_source("sdk/lib/minga_agent/inference_route/#{value}.ex", type),
             "#{value} #{type} drifted"
    end

    assert error_kinds("lib/minga_agent/event.ex", :kind) ==
             error_kinds("sdk/lib/minga_agent/inference_route.ex", :error_kind)
  end

  @spec type_source(String.t(), atom()) :: String.t()
  defp type_source(path, type_name) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, matches} =
      Macro.prewalk(ast, [], fn
        {:@, _meta, [{:type, _type_meta, [{:"::", _spec_meta, [{^type_name, _, _}, body]}]}]} =
            node,
        acc ->
          {node, [Macro.to_string(strip_meta(body)) | acc]}

        node, acc ->
          {node, acc}
      end)

    case matches do
      [source] -> source
      _ -> flunk("expected one @type #{type_name} in #{path}")
    end
  end

  @spec strip_meta(Macro.t()) :: Macro.t()
  defp strip_meta(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _meta -> [] end))

  @spec struct_fields(String.t()) :: [atom()]
  defp struct_fields(path) do
    module = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, fields} =
      Macro.prewalk(module, [], fn
        {:@, _meta, [{:enforce_keys, _key_meta, [keys]}]} = node, acc when is_list(keys) ->
          {node, keys ++ acc}

        {:defstruct, _meta, [fields]} = node, acc when is_list(fields) ->
          {node, Enum.map(fields, &field_name/1) ++ acc}

        node, acc ->
          {node, acc}
      end)

    fields |> Enum.uniq() |> Enum.sort()
  end

  @spec field_name(atom() | {atom(), term()}) :: atom()
  defp field_name({name, _default}), do: name
  defp field_name(name) when is_atom(name), do: name

  @spec error_kinds(String.t(), atom()) :: [atom()]
  defp error_kinds(path, type_name), do: named_union_literals(path, type_name)

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

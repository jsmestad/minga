defmodule Minga.Extension.SdkContractTest do
  use ExUnit.Case, async: true

  # Stub modules whose runtime counterpart is a large host module.
  # The SDK exposes a deliberate subset, so only SDK-to-runtime is checked.
  @subset_modules %{
    Minga.Buffer =>
      "Buffer stubs cover the read and edit calls extensions use; the host API is much larger.",
    Minga.Buffer.EditDelta => "Value type; host construction helpers stay internal.",
    Minga.Buffer.EditSource => "Value type; host construction helpers stay internal.",
    Minga.Events =>
      "Extensions subscribe to documented topics; registry plumbing stays in the host."
  }

  # Runtime functions that extensions must not call or never need, by reason.
  @host_only %{
    lifecycle: "Host supervision and source cleanup, called by Minga, never by extensions.",
    injected_server: "Same operation with an extra server or table argument used by host tests.",
    render_read: "Read side consumed by Minga's renderer, not by extensions.",
    host_dispatch: "Host input routing and focus, driven by Minga.",
    host_construction:
      "Host-side constructors and validators; extensions use struct literals or register/2."
  }

  @runtime_only %{
    Minga.Extension.Badge => %{
      {:start_link, 1} => :lifecycle,
      {:unregister_source, 1} => :lifecycle,
      {:set_file, 4} => :injected_server,
      {:remove_file, 3} => :injected_server,
      {:set_tab, 4} => :injected_server,
      {:remove_tab, 3} => :injected_server,
      {:remove_all, 3} => :injected_server,
      {:all_file_badges, 0} => :render_read,
      {:all_file_badges, 1} => :render_read,
      {:all_tab_badges, 0} => :render_read,
      {:all_tab_badges, 1} => :render_read,
      {:badges_for_buffer, 1} => :render_read,
      {:badges_for_buffer, 2} => :render_read,
      {:badges_for_path, 1} => :render_read,
      {:badges_for_path, 2} => :render_read,
      {:file_levels_map, 0} => :render_read,
      {:file_levels_map, 1} => :render_read
    },
    Minga.Extension.Overlay => %{
      {:start_link, 1} => :lifecycle,
      {:unregister_source, 1} => :lifecycle,
      {:set, 5} => :injected_server,
      {:remove, 3} => :injected_server,
      {:remove_all, 2} => :injected_server,
      {:for_buffer, 2} => :injected_server,
      {:all, 1} => :injected_server,
      {:empty?, 1} => :injected_server
    },
    Minga.Extension.Panel => %{
      {:start_link, 1} => :lifecycle,
      {:unregister_source, 1} => :lifecycle,
      {:set, 4} => :injected_server,
      {:remove, 3} => :injected_server,
      {:remove_all, 2} => :injected_server,
      {:all, 0} => :render_read,
      {:all, 1} => :render_read,
      {:empty?, 0} => :render_read,
      {:empty?, 1} => :render_read,
      {:visible, 0} => :render_read,
      {:visible, 1} => :render_read
    },
    MingaEditor.Extension.Sidebar => %{
      {:start_link, 1} => :lifecycle,
      {:unregister_source, 1} => :lifecycle,
      {:unregister_source, 2} => :lifecycle,
      {:default_table, 0} => :lifecycle,
      {:table_for, 1} => :lifecycle,
      {:register, 3} => :injected_server,
      {:unregister, 3} => :injected_server,
      {:publish_snapshot, 4} => :injected_server,
      {:set_visible, 4} => :injected_server,
      {:set_focused, 4} => :injected_server,
      {:all, 0} => :render_read,
      {:all, 1} => :render_read,
      {:get, 1} => :render_read,
      {:get, 2} => :render_read,
      {:visible, 0} => :render_read,
      {:visible, 1} => :render_read,
      {:active_left, 0} => :render_read,
      {:active_left, 1} => :render_read,
      {:dispatch_action, 4} => :host_dispatch,
      {:dispatch_action, 5} => :host_dispatch,
      {:focus_left, 1} => :host_dispatch,
      {:focus_left, 2} => :host_dispatch
    },
    MingaEditor.Extension.Sidebar.Snapshot => %{
      {:new, 0} => :host_construction,
      {:new, 1} => :host_construction,
      {:selection_only_change?, 2} => :render_read
    },
    MingaAgent.InferenceRoute => %{{:callbacks, 0} => :host_construction},
    MingaAgent.InferenceRoute.ConversationRef => %{{:new, 1} => :host_construction},
    MingaAgent.InferenceRoute.Credential => %{{:new, 1} => :host_construction},
    MingaAgent.InferenceRoute.Event => %{{:validate, 1} => :host_construction},
    MingaAgent.InferenceRoute.Model => %{{:validate, 1} => :host_construction},
    MingaAgent.InferenceRoute.Reporter => %{{:issue, 1} => :host_construction},
    MingaAgent.InferenceRoute.Spec => %{
      {:new, 1} => :host_construction,
      {:reserved_ids, 0} => :host_construction,
      {:short_name, 1} => :render_read
    },
    MingaAgent.InferenceRoute.Status => %{
      {:new, 1} => :host_construction,
      {:unknown, 0} => :host_construction,
      {:ready?, 1} => :host_construction,
      {:account_label, 1} => :host_construction,
      {:with_availability, 2} => :host_construction,
      {:with_plan_usage, 2} => :host_construction
    },
    MingaAgent.InferenceRoute.PlanWindow => %{
      {:new_list, 1} => :host_construction,
      {:busiest, 1} => :render_read,
      {:rejected, 1} => :render_read,
      {:kind_label, 1} => :render_read,
      {:percent, 1} => :render_read,
      {:reset_label, 3} => :render_read
    },
    MingaAgent.InferenceRoute.SetupAction => %{{:new, 1} => :host_construction},
    MingaAgent.InferenceRoute.Usage => %{{:validate, 1} => :host_construction}
  }

  test "every SDK stub function exists in the running engine" do
    assert sdk_runtime_mismatches(sdk_stub_files()) == []
  end

  test "extension-facing runtime functions are stubbed or explicitly host-only" do
    missing =
      for {module, sdk_functions} <- sdk_public_functions(sdk_stub_files()),
          not Map.has_key?(@subset_modules, module),
          {name, arity} <- runtime_public_functions(module),
          {name, arity} not in sdk_functions,
          not Map.has_key?(Map.get(@runtime_only, module, %{}), {name, arity}),
          do: {module, name, arity}

    assert missing == []

    for {_module, entries} <- @runtime_only, {_function, reason} <- entries do
      assert Map.has_key?(@host_only, reason)
    end
  end

  test "the guard reports a stub the engine does not define" do
    stub = """
    defmodule MingaEditor.Extension.EditorAPI do
      def set_status(_state, _message), do: raise("minga_sdk is compile-time only")
      def active_path(_state), do: raise("minga_sdk is compile-time only")
    end
    """

    path = Path.join(System.tmp_dir!(), "sdk_guard_#{System.unique_integer([:positive])}.ex")
    File.write!(path, stub)
    on_exit(fn -> File.rm(path) end)

    assert sdk_runtime_mismatches([path]) == [{MingaEditor.Extension.EditorAPI, :set_status, 2}]
  end

  @spec sdk_stub_files() :: [String.t()]
  defp sdk_stub_files do
    "sdk/lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(&1, "sdk/lib/declarations/"))
  end

  @spec sdk_runtime_mismatches([String.t()]) :: [{module(), atom(), arity()}]
  defp sdk_runtime_mismatches(files) do
    for {module, functions} <- sdk_public_functions(files),
        {name, arity} <- Enum.sort(functions),
        not runtime_exports?(module, name, arity),
        do: {module, name, arity}
  end

  @spec runtime_exports?(module(), atom(), arity()) :: boolean()
  defp runtime_exports?(module, name, arity) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, name, arity) or macro_exported?(module, name, arity))
  end

  @spec runtime_public_functions(module()) :: [{atom(), arity()}]
  defp runtime_public_functions(module) do
    {:docs_v1, _anno, _language, _format, _moduledoc, _meta, docs} = Code.fetch_docs(module)

    for {{kind, name, arity}, _anno, _signature, doc, _meta} <- docs,
        kind in [:function, :macro],
        doc != :hidden,
        do: {name, arity}
  end

  @spec sdk_public_functions([String.t()]) :: %{module() => MapSet.t({atom(), arity()})}
  defp sdk_public_functions(files) do
    files
    |> Enum.flat_map(fn path ->
      path |> File.read!() |> Code.string_to_quoted!(file: path) |> module_defs([], [])
    end)
    |> Enum.reduce(%{}, fn {module, function}, acc ->
      Map.update(
        acc,
        module,
        MapSet.new(List.wrap(function)),
        &MapSet.union(&1, MapSet.new(List.wrap(function)))
      )
    end)
  end

  @spec module_defs(Macro.t(), [module()], list()) :: list()
  defp module_defs({:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}, stack, acc) do
    module = Module.concat(stack ++ parts)
    module_defs(body, [module], [{module, []} | acc])
  end

  defp module_defs({:__block__, _meta, items}, stack, acc),
    do: Enum.reduce(items, acc, &module_defs(&1, stack, &2))

  defp module_defs({kind, _meta, [head | _rest]}, [module | _], acc)
       when kind in [:def, :defmacro] do
    {name, args} = def_head(head)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))

    Enum.reduce((length(args) - defaults)..length(args)//1, acc, fn arity, acc ->
      [{module, [{name, arity}]} | acc]
    end)
  end

  defp module_defs(_other, _stack, acc), do: acc

  @spec def_head(Macro.t()) :: {atom(), list()}
  defp def_head({:when, _meta, [head | _guards]}), do: def_head(head)
  defp def_head({name, _meta, args}) when is_list(args), do: {name, args}
  defp def_head({name, _meta, nil}), do: {name, []}

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

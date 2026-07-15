defmodule Minga.Extension.CompilerGuardrailTest do
  use ExUnit.Case, async: true

  @extension_files Path.wildcard("lib/minga/extension/**/*.ex")

  test "path and Git flows have no host compiler or runtime module creation bypass" do
    forbidden = [
      {Code, :compile_file},
      {Code, :compile_string},
      {Code, :compile_quoted},
      {Module, :create},
      {Kernel.ParallelCompiler, :compile},
      {Kernel.ParallelCompiler, :compile_to_path}
    ]

    files =
      @extension_files --
        [
          "lib/minga/extension/isolated_compiler.ex",
          "lib/minga/extension/json_loader.ex"
        ]

    assert calls_in(files, forbidden) == []

    json_calls = calls_in(["lib/minga/extension/json_loader.ex"], forbidden)
    assert [{"lib/minga/extension/json_loader.ex", _line, Module, :create}] = json_calls

    isolated_calls = calls_in(["lib/minga/extension/isolated_compiler.ex"], forbidden)

    assert [
             {"lib/minga/extension/isolated_compiler.ex", _line, Kernel.ParallelCompiler,
              :compile_to_path}
           ] = isolated_calls
  end

  test "extension compilation and validation have no distribution or ETF control channel" do
    forbidden = [
      {:peer, :start},
      {:peer, :start_link},
      {:peer, :call},
      {:peer, :stop},
      {:erpc, :call},
      {:erlang, :binary_to_term}
    ]

    files = [
      "lib/minga/extension/disposable_beam.ex",
      "lib/minga/extension/isolated_compiler.ex",
      "lib/minga/extension/artifact_validator.ex",
      "lib/minga/extension/artifact_inventory.ex"
    ]

    assert calls_in(files, forbidden) == []
  end

  test "updater has no compiler, extension lifecycle, dependency reinstall, or code-load path" do
    forbidden = [
      {Minga.Extension.CompileCache, :load_or_compile},
      {CompileCache, :load_or_compile},
      {Minga.Extension.Supervisor, :start_extension},
      {Minga.Extension.Supervisor, :stop_extension},
      {ExtSupervisor, :start_extension},
      {ExtSupervisor, :stop_extension},
      {Minga.Extension.Hex, :reinstall_all},
      {ExtHex, :reinstall_all},
      {:code, :load_binary}
    ]

    assert calls_in(["lib/minga/extension/updater.ex"], forbidden) == []
    assert File.read!("lib/minga/extension/updater.ex") =~ "restart Minga to activate"
  end

  test "code deletion and purge exist only inside attempt-local rollback functions" do
    rollback_owners = [
      {"lib/minga/extension/compile_cache.ex", :rollback_loaded},
      {"lib/minga/extension/json_loader.ex", :unload_created_module}
    ]

    rollback_files = Enum.map(rollback_owners, &elem(&1, 0))
    files = @extension_files -- rollback_files
    forbidden = [{:code, :delete}, {:code, :purge}, {:code, :soft_purge}]
    assert calls_in(files, forbidden) == []

    Enum.each(rollback_owners, fn {file, expected_owner} ->
      owners = forbidden_call_owners(file, forbidden)
      assert owners != []

      assert Enum.all?(owners, fn {name, arity, _module, _function} ->
               name == expected_owner and arity == 1
             end)
    end)

    refute File.exists?("lib/minga/extension/dev_reload.ex")
  end

  defp forbidden_call_owners(file, forbidden) do
    ast = file |> File.read!() |> Code.string_to_quoted!(file: file)

    {_ast, owners} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [{name, _name_meta, args}, [do: body]]} = node, acc
        when kind in [:def, :defp] and is_atom(name) and is_list(args) ->
          calls = calls_in_ast(body, forbidden)

          entries =
            Enum.map(calls, fn {module, function} -> {name, length(args), module, function} end)

          {node, entries ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(owners)
  end

  defp calls_in_ast(ast, forbidden) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _meta, [module_ast, function]}, _call_meta, _args} = node, acc
        when is_atom(function) ->
          call = {expand_module(module_ast), function}
          if call in forbidden, do: {node, [call | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp calls_in(files, forbidden) do
    Enum.flat_map(files, fn file ->
      ast = file |> File.read!() |> Code.string_to_quoted!(file: file)

      {_ast, calls} =
        Macro.prewalk(ast, [], fn
          {{:., meta, [module_ast, function]}, _call_meta, _args} = node, acc
          when is_atom(function) ->
            module = expand_module(module_ast)
            record_forbidden_call(node, acc, file, meta[:line], module, function, forbidden)

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(calls)
    end)
  end

  defp record_forbidden_call(node, acc, file, line, module, function, forbidden) do
    if {module, function} in forbidden,
      do: {node, [{file, line, module, function} | acc]},
      else: {node, acc}
  end

  defp expand_module({:__aliases__, _meta, parts}), do: Module.concat(parts)
  defp expand_module(module) when is_atom(module), do: module
  defp expand_module(_other), do: nil
end

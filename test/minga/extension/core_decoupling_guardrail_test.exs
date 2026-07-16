defmodule Minga.Extension.CoreDecouplingGuardrailTest do
  @moduledoc "Guards the runtime boundary between editor core and bundled extensions."

  use ExUnit.Case, async: true

  @core_files Path.wildcard("lib/**/*.ex")
  @registry_key_allowlist [
    "lib/minga/config/loader.ex",
    "lib/minga/extension/bundled_applications.ex"
  ]
  @concrete_namespace "MingaGitPorcelain"
  @extension_registry_key :minga_git_porcelain

  test "core contains no concrete bundled extension namespaces or optional probes" do
    violations =
      Enum.flat_map(@core_files, fn file ->
        file
        |> File.read!()
        |> Code.string_to_quoted!(file: file, columns: true)
        |> collect_namespace_violations(file)
      end)

    assert violations == [], format_violations(violations)
  end

  test "only bundled extension composition roots name the extension registry key" do
    violations =
      @core_files
      |> Enum.reject(&(&1 in @registry_key_allowlist))
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> Code.string_to_quoted!(file: file, columns: true)
        |> collect_registry_key_violations(file)
      end)

    assert violations == [], format_violations(violations)
  end

  @spec collect_namespace_violations(Macro.t(), String.t()) :: [tuple()]
  defp collect_namespace_violations(ast, file) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {{:., _, [receiver, function]}, meta, arguments} = node, acc
        when function in [:ensure_loaded?, :function_exported?] ->
          violation =
            if concrete_extension_term?(receiver) or
                 Enum.any?(arguments, &concrete_extension_term?/1) do
              [{file, Keyword.get(meta, :line, 0), :optional_extension_probe}]
            else
              []
            end

          {node, violation ++ acc}

        {:__aliases__, meta, parts} = node, acc ->
          violation =
            if Enum.all?(parts, &is_atom/1) and concrete_namespace?(Module.concat(parts)) do
              [{file, Keyword.get(meta, :line, 0), :concrete_extension_namespace}]
            else
              []
            end

          {node, violation ++ acc}

        atom, acc when is_atom(atom) ->
          violation =
            if concrete_namespace?(atom),
              do: [{file, 0, :concrete_extension_namespace}],
              else: []

          {atom, violation ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(violations)
  end

  @spec collect_registry_key_violations(Macro.t(), String.t()) :: [tuple()]
  defp collect_registry_key_violations(ast, file) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        @extension_registry_key = node, acc ->
          {node, [{file, 0, :extension_registry_key} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(violations)
  end

  @spec concrete_extension_term?(Macro.t()) :: boolean()
  defp concrete_extension_term?({:__aliases__, _meta, parts}) do
    Enum.all?(parts, &is_atom/1) and concrete_namespace?(Module.concat(parts))
  end

  defp concrete_extension_term?(atom) when is_atom(atom), do: concrete_namespace?(atom)
  defp concrete_extension_term?(_term), do: false

  @spec concrete_namespace?(atom()) :: boolean()
  defp concrete_namespace?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.contains?(@concrete_namespace)
  end

  @spec format_violations([tuple()]) :: String.t()
  defp format_violations(violations) do
    Enum.map_join(violations, "\n", fn {file, line, kind} ->
      "#{file}:#{line}: #{kind}"
    end)
  end
end

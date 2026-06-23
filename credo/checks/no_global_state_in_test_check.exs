defmodule Minga.Credo.NoGlobalStateInTestCheck do
  @moduledoc """
  Flags global-state mutations inside test modules.

  Tests that mutate Application env, system env, ETS tables, persistent terms,
  or the process registry create ordering-dependent failures and prevent safe
  parallelism. Isolate the state instead: inject it as a parameter, use
  `start_supervised!` with a unique name, or use a test-local ETS table.
  """

  use Credo.Check,
    id: "EX9011",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Global-state mutations in tests cause intermittent failures that depend
      on test execution order. The fix is to isolate the state source: pass it
      as a parameter, use `start_supervised!` with a unique name, or use a
      test-local ETS table.
      """
    ]

  @global_state_calls [
    {[:Application], :put_env, "Application.put_env"},
    {[:Application], :delete_env, "Application.delete_env"},
    {[:System], :put_env, "System.put_env"},
    {[:System], :delete_env, "System.delete_env"},
    {[:persistent_term], :put, ":persistent_term.put"},
    {[:persistent_term], :erase, ":persistent_term.erase"},
    {[:ets], :insert, ":ets.insert"},
    {[:ets], :delete, ":ets.delete"},
    {[:ets], :delete_object, ":ets.delete_object"},
    {[:ets], :delete_all_objects, ":ets.delete_all_objects"},
    {[:Process], :register, "Process.register"},
    {[:EventBus], :broadcast, "EventBus.broadcast"},
    {[:Minga, :EventBus], :broadcast, "Minga.EventBus.broadcast"}
  ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&find_global_state_calls(&1, &2, issue_meta))
      |> List.flatten()
    else
      []
    end
  end

  # Erlang module calls: :ets.insert(...), :persistent_term.put(...)
  defp find_global_state_calls(
         {{:., _, [mod_atom, func]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when is_atom(mod_atom) and is_atom(func) do
    case find_match([mod_atom], func) do
      nil -> {ast, issues}
      trigger -> {ast, [make_issue(issue_meta, trigger, meta[:line]) | issues]}
    end
  end

  # Elixir module calls: Application.put_env(...), EventBus.broadcast(...)
  defp find_global_state_calls(
         {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when is_atom(func) do
    case find_match(mod_parts, func) do
      nil -> {ast, issues}
      trigger -> {ast, [make_issue(issue_meta, trigger, meta[:line]) | issues]}
    end
  end

  defp find_global_state_calls(ast, issues, _issue_meta), do: {ast, issues}

  defp find_match(mod_parts, func) do
    Enum.find_value(@global_state_calls, fn {expected_parts, expected_func, trigger} ->
      if mod_parts == expected_parts and func == expected_func, do: trigger
    end)
  end

  defp make_issue(issue_meta, trigger, line_no) do
    format_issue(issue_meta,
      message: "#{trigger} mutates global state in a test. Isolate the state source instead.",
      trigger: trigger,
      line_no: line_no
    )
  end

  defp test_file?(%SourceFile{} = source_file) do
    filename = Path.expand(source_file.filename)
    String.contains?(filename, "/test/") and not String.ends_with?(filename, "/test_helper.exs")
  end
end

defmodule Minga.Credo.NoBlockingEditorCallCheck do
  @moduledoc """
  Flags synchronous blocking calls inside MingaEditor modules.

  MingaEditor is a single GenServer. Synchronous calls to LSP (`Client.request_sync`), shell commands (`System.cmd`), task awaits (`Task.await`), and sleeps (`Process.sleep`) inside command and handler code head-of-line-block input echo and rendering. Slow domain work should use a typed `EffectScheduler` request or a supervised Task instead.

  Calls nested inside `Task.start`/`Task.async` bodies are exempt because the work is already off the critical path.

  ## Inline suppression

  Add `# minga:allow-blocking — <justification>` on the same line as a sanctioned blocking call to suppress the warning. The justification after the dash is required; a bare `# minga:allow-blocking` without explanation will not suppress.

  ## Limitations

  This check matches syntactic call tokens in-module only. A blocking call reached through a helper or another module (e.g. `format_and_replace/3` calling `Minga.Editing.format/2` which calls `System.cmd`) is invisible to it. It catches the copy-paste regression, not transitive blocking. Per-site review (D2) is the real isolation guarantee; this check is a regression tripwire.

  See responsiveness epic #2445 (D2/D3) for the full rationale.
  """

  use Credo.Check,
    id: "EX9008",
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      `Client.request_sync`, `System.cmd`, `Task.await`, and `Process.sleep` block the calling process. Inside MingaEditor modules these block the single editor GenServer, causing head-of-line blocking for input echo and rendering.

      Use a typed `EffectScheduler` request or a supervised Task to move slow work off the critical path.

      To suppress a sanctioned exception, add `# minga:allow-blocking — <justification>` on the same line.
      """
    ]

  @blocking_calls [
    {[:Client], :request_sync},
    {[:Minga, :LSP, :Client], :request_sync},
    {[:System], :cmd},
    {[:Task], :await},
    {[:Process], :sleep}
  ]

  @exempt_wrappers [
    {[:Task], :start},
    {[:Task], :start_link},
    {[:Task], :async}
  ]

  @suppression_pattern ~r/# minga:allow-blocking\s+—\s+\S/

  # Known blocking-call sites awaiting D2 migration (#2450).
  # Remove entries as each site moves to a typed effect or supervised Task.
  @known_sites [
    {"lib/minga_editor/commands/formatting.ex", 72},
    {"lib/minga_editor/commands/buffer_management.ex", 2198},
    {"lib/minga_editor/ui/picker/workspace_symbol_source.ex", 46},
    {"lib/minga_editor/ui/picker/code_action_source.ex", 114},
    {"lib/minga_editor/agent/slash_command.ex", 1293},
    {"lib/minga_editor/agent/slash_command.ex", 1371},
    {"lib/minga_editor/ui/picker/todo_search_source.ex", 99},
    {"lib/minga_editor/ui/picker/todo_search_source.ex", 119}
  ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      ast = SourceFile.ast(source_file)
      source_lines = source_file |> SourceFile.source() |> String.split("\n")

      ast
      |> find_blocking_calls(issue_meta, false)
      |> Enum.reject(&known_site?(source_file, &1))
      |> Enum.reject(&suppressed_by_comment?(source_lines, &1))
    end
  end

  defp find_blocking_calls(ast, issue_meta, exempt?) do
    case ast do
      # Pipe into an exempt Task wrapper.
      {:|>, meta, [_lhs, {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, args}]}
      when is_list(args) ->
        if exempt_wrapper?(mod_parts, func) do
          exempt_args_issues(args, issue_meta)
        else
          issues_for_node(mod_parts, func, meta, issue_meta, exempt?) ++
            children_issues(args, issue_meta, exempt?)
        end

      # Direct call to an exempt Task wrapper.
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, args} when is_list(args) ->
        if exempt_wrapper?(mod_parts, func) do
          exempt_args_issues(args, issue_meta)
        else
          issues_for_node(mod_parts, func, meta, issue_meta, exempt?) ++
            children_issues(args, issue_meta, exempt?)
        end

      # fn -> ... end (anonymous function body)
      {:fn, _meta, clauses} when is_list(clauses) ->
        Enum.flat_map(clauses, fn clause -> find_blocking_calls(clause, issue_meta, exempt?) end)

      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.flat_map(fn child -> find_blocking_calls(child, issue_meta, exempt?) end)

      list when is_list(list) ->
        Enum.flat_map(list, fn child -> find_blocking_calls(child, issue_meta, exempt?) end)

      _ ->
        []
    end
  end

  defp exempt_args_issues(args, issue_meta) do
    Enum.flat_map(args, fn arg -> find_blocking_calls(arg, issue_meta, true) end)
  end

  defp issues_for_node(mod_parts, func, meta, issue_meta, false = _exempt?) do
    if blocking_call?(mod_parts, func) do
      trigger = Enum.map_join(mod_parts, ".", &Atom.to_string/1) <> ".#{func}"

      [
        format_issue(issue_meta,
          message:
            "#{trigger} blocks the editor GenServer. Use a typed EffectScheduler request or supervised Task to move this off the critical path.",
          trigger: trigger,
          line_no: meta[:line]
        )
      ]
    else
      []
    end
  end

  defp issues_for_node(_mod_parts, _func, _meta, _issue_meta, true = _exempt?), do: []

  defp children_issues(args, issue_meta, exempt?) do
    Enum.flat_map(args, fn arg -> find_blocking_calls(arg, issue_meta, exempt?) end)
  end

  defp blocking_call?(mod_parts, func) do
    Enum.any?(@blocking_calls, fn {expected_parts, expected_func} ->
      func == expected_func && mod_parts == expected_parts
    end)
  end

  defp exempt_wrapper?(mod_parts, func) do
    Enum.any?(@exempt_wrappers, fn {expected_parts, expected_func} ->
      func == expected_func && mod_parts == expected_parts
    end)
  end

  defp suppressed_by_comment?(source_lines, issue) do
    line_index = (issue.line_no || 0) - 1

    case Enum.at(source_lines, line_index) do
      nil -> false
      line -> Regex.match?(@suppression_pattern, line)
    end
  end

  defp known_site?(%SourceFile{} = source_file, issue) do
    rel_path = source_file.filename |> Path.expand() |> project_relative_path()
    Enum.any?(@known_sites, fn {path, line} -> rel_path == path and issue.line_no == line end)
  end

  defp project_relative_path(abs_path) do
    project_root = File.cwd!()

    case Path.relative_to(abs_path, project_root) do
      ^abs_path -> abs_path
      rel -> rel
    end
  end

  @supervisor_modules [
    "lib/minga_editor/frontend/resolve.ex"
  ]

  defp skip_file?(%SourceFile{} = source_file) do
    filename = Path.expand(source_file.filename)

    not String.contains?(filename, "/minga_editor/") or
      String.contains?(filename, "/test/") or
      supervisor_context?(source_file)
  end

  defp supervisor_context?(%SourceFile{} = source_file) do
    rel_path = source_file.filename |> Path.expand() |> project_relative_path()
    rel_path in @supervisor_modules
  end
end

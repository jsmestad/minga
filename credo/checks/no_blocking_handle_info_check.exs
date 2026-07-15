defmodule Minga.Credo.NoBlockingHandleInfoCheck do
  @moduledoc """
  Flags expensive synchronous work inlined directly in `handle_info/2` clauses of MingaEditor modules.

  MingaEditor is a single GenServer. Its mailbox processes input, render, and timer messages in order, so any `handle_info` clause that does expensive synchronous work inline head-of-line-blocks input echo and rendering until it returns. A 1-second filesystem walk or unbounded `Enum.reduce` in a `handle_info` clause freezes the UI for that whole second.

  This is the structural guard against the recurring class of bug where a new feature blocks the Editor mailbox. Expensive work that arrives as a message must be re-dispatched off the hot path: submit a typed `EffectScheduler` request, spawn a supervised Task, schedule it with `Process.send_after`, or `GenServer.cast` it elsewhere, then apply the result in a later, cheap `handle_info`.

  The check flags a `handle_info` clause whose body directly calls a known-expensive primitive:

    * filesystem walks: `File.ls`, `File.lstat`, `File.stat`, `File.dir?`, `File.read`, `File.cp_r`, `File.rm_rf`, and their bang variants
    * unbounded iteration: `Enum.map`, `Enum.reduce`, `Enum.flat_map`, `Enum.each`, `Enum.filter`, `Enum.reduce_while`, `Enum.map_reduce` over a non-literal collection
    * cross-process synchronous calls: `GenServer.call`
    * synchronous LSP/request calls: any `*.request_sync`

  Calls nested inside a sanctioned async wrapper (`Task.async`/`start`/`start_link`, `Task.Supervisor.*`, `Process.send_after`, `GenServer.cast`) are exempt, because that work already runs off the critical path.

  ## Allowlist

  Known clauses whose expensive work is being migrated on separate in-flight branches are suppressed by their message tag in `@allowlisted_tags` (extend at runtime with the `allow` param). Each entry carries the issue number of the fix in flight; remove the entry when that branch merges.

  ## Inline suppression

  Add `# minga:allow-blocking — <justification>` on the same line as a sanctioned inline call to suppress the warning. The justification after the dash is required.

  ## Limitations

  This check matches calls written directly in the `handle_info` clause body. Expensive work reached transitively through a helper or another module (e.g. `handle_info(:file_tree_refresh_timer, ...)` delegating to `FileEventHandler.handle/2`, which calls `FileTreeFreshness.flush_refresh/1`, which does sync filesystem I/O) is invisible to it, exactly like the sibling `NoBlockingEditorCallCheck`. It catches the copy-paste regression that inlines blocking work in a new clause, not transitive blocking; per-site review remains the real isolation guarantee. The known in-flight violators (`:observatory_tick`, `:file_tree_refresh_timer`, `:picker_candidates_result`) delegate to such cross-module helpers and so are recorded in the allowlist as a paper trail rather than being detectable inline.

  See responsiveness epic #2445 (D2/D3) for the full rationale.
  """

  use Credo.Check,
    id: "EX9009",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Expensive synchronous work inside a MingaEditor `handle_info/2` clause blocks the single editor GenServer mailbox, freezing input echo and rendering until it returns.

      Re-dispatch the work off the hot path with a typed `EffectScheduler` request, supervised Task, `Process.send_after`, or `GenServer.cast`, and apply the result in a later cheap `handle_info` clause.

      To suppress a sanctioned exception, add `# minga:allow-blocking — <justification>` on the same line.
      """
    ]

  @file_walk_funcs [
    :ls,
    :ls!,
    :lstat,
    :lstat!,
    :stat,
    :stat!,
    :dir?,
    :read,
    :read!,
    :cp_r,
    :cp_r!,
    :rm_rf,
    :rm_rf!
  ]

  @enum_funcs [:map, :reduce, :flat_map, :each, :filter, :reduce_while, :map_reduce]

  @exempt_wrappers [
    {[:Task], :async},
    {[:Task], :start},
    {[:Task], :start_link},
    {[:Task], :async_nolink},
    {[:Task, :Supervisor], :start_child},
    {[:Task, :Supervisor], :async},
    {[:Task, :Supervisor], :async_nolink},
    {[:Process], :send_after},
    {[:GenServer], :cast}
  ]

  @suppression_pattern ~r/# minga:allow-blocking\s+—\s+\S/

  # Known `handle_info` clauses whose expensive work is being migrated on
  # separate in-flight branches. Each clause delegates to a cross-module helper
  # that does sync work, so the primitive is not visible inline; these entries
  # are an explicit paper trail (AC#3) and a forward-guard against an
  # intermediate refactor surfacing a primitive on this branch.
  # Remove each entry as its branch merges.
  @allowlisted_tags [
    # allowlisted: fix in flight on #2631 (observatory tick → blocking GenServer.call every 1s)
    :observatory_tick,
    # allowlisted: fix in flight on #2632 (file-tree refresh → sync filesystem I/O)
    :file_tree_refresh_timer
  ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      source_lines = source_file |> SourceFile.source() |> String.split("\n")
      allowlist = @allowlisted_tags ++ List.wrap(Keyword.get(params, :allow, []))

      source_file
      |> SourceFile.ast()
      |> collect_handle_info_clauses()
      |> Enum.reject(fn {tag, _body} -> tag in allowlist end)
      |> Enum.flat_map(fn {_tag, body} -> find_blocking_calls(body, issue_meta) end)
      |> Enum.reject(&suppressed_by_comment?(source_lines, &1))
    end
  end

  # ── Locate handle_info clauses ─────────────────────────────────────────────

  defp collect_handle_info_clauses(ast) do
    {_ast, clauses} =
      Macro.prewalk(ast, [], fn node, acc ->
        case handle_info_clause(node) do
          {:ok, tag, body} -> {node, [{tag, body} | acc]}
          :no -> {node, acc}
        end
      end)

    clauses
  end

  defp handle_info_clause({:def, _meta, [head, body_kw]}) when is_list(body_kw) do
    case head do
      {:when, _, [{:handle_info, _, [pattern, _state]}, _guard]} ->
        {:ok, message_tag(pattern), clause_body(body_kw)}

      {:handle_info, _, [pattern, _state]} ->
        {:ok, message_tag(pattern), clause_body(body_kw)}

      _ ->
        :no
    end
  end

  defp handle_info_clause(_node), do: :no

  defp clause_body(body_kw) do
    body_kw
    |> Keyword.take([:do, :rescue, :catch, :after])
    |> Keyword.values()
  end

  # Extract the message tag used for allowlisting: the leading atom of the
  # matched message pattern.
  defp message_tag({:=, _, [lhs, _rhs]}), do: message_tag(lhs)
  defp message_tag(tag) when is_atom(tag), do: tag
  defp message_tag({:{}, _, [tag | _rest]}) when is_atom(tag), do: tag
  defp message_tag({tag, _second}) when is_atom(tag), do: tag
  defp message_tag(_pattern), do: nil

  # ── Detect blocking primitives within a clause body ────────────────────────

  defp find_blocking_calls(ast, issue_meta) do
    case ast do
      # Pipe into a remote call: lhs |> Mod.fun(args). The piped value becomes
      # the real first argument, so scan the lhs too.
      {:|>, _meta, [lhs, {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, args}]}
      when is_list(args) ->
        find_blocking_calls(lhs, issue_meta) ++
          remote_call_issues(mod_parts, func, [:piped | args], meta, issue_meta)

      # Direct remote call: Mod.fun(args)
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, args} when is_list(args) ->
        remote_call_issues(mod_parts, func, args, meta, issue_meta)

      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.flat_map(fn child -> find_blocking_calls(child, issue_meta) end)

      list when is_list(list) ->
        Enum.flat_map(list, fn child -> find_blocking_calls(child, issue_meta) end)

      _ ->
        []
    end
  end

  # Work inside an async wrapper already runs off the hot path, so we do not
  # descend into its body.
  defp remote_call_issues(mod_parts, func, args, meta, issue_meta) do
    if exempt_wrapper?(mod_parts, func) do
      []
    else
      blocking_issue_or_descend(mod_parts, func, args, meta, issue_meta)
    end
  end

  defp blocking_issue_or_descend(mod_parts, func, args, meta, issue_meta) do
    if blocking?(mod_parts, func, args) do
      trigger = Enum.map_join(mod_parts, ".", &Atom.to_string/1) <> ".#{func}"

      [
        format_issue(issue_meta,
          message:
            "#{trigger} runs inline in a handle_info clause and blocks the editor GenServer mailbox. Re-dispatch via a typed EffectScheduler request, supervised Task, Process.send_after, or GenServer.cast.",
          trigger: trigger,
          line_no: meta[:line]
        )
      ]
    else
      Enum.flat_map(args, fn arg -> find_blocking_calls(arg, issue_meta) end)
    end
  end

  defp blocking?([:File], func, _args), do: func in @file_walk_funcs
  defp blocking?([:GenServer], :call, _args), do: true
  defp blocking?(_mod_parts, :request_sync, _args), do: true

  defp blocking?([:Enum], func, args) when func in @enum_funcs do
    case strip_pipe(args) do
      [first | _] -> not literal_collection?(first)
      [] -> false
    end
  end

  defp blocking?(_mod_parts, _func, _args), do: false

  # When the call is the rhs of a pipe, the real first argument is the piped lhs
  # (an upstream expression), which is by definition not a bounded literal.
  defp strip_pipe([:piped | rest]), do: [{:piped_value, [], nil} | rest]
  defp strip_pipe(args), do: args

  # A list literal or a small explicit range is bounded; anything else (a
  # variable, map field, or function result) is treated as unbounded.
  defp literal_collection?(arg) when is_list(arg), do: true
  defp literal_collection?({:.., _, [_lo, _hi]}), do: false
  defp literal_collection?(_arg), do: false

  defp exempt_wrapper?(mod_parts, func) do
    Enum.any?(@exempt_wrappers, fn {parts, expected} ->
      func == expected and mod_parts == parts
    end)
  end

  defp suppressed_by_comment?(source_lines, issue) do
    line_index = (issue.line_no || 0) - 1

    case Enum.at(source_lines, line_index) do
      nil -> false
      line -> Regex.match?(@suppression_pattern, line)
    end
  end

  # ── Scope filtering ────────────────────────────────────────────────────────

  defp skip_file?(%SourceFile{} = source_file) do
    filename = Path.expand(source_file.filename)
    test_file?(filename) or not editor_file?(filename)
  end

  defp test_file?(filename), do: String.contains?(filename, "/test/")

  defp editor_file?(filename) do
    String.contains?(filename, "/minga_editor/") or
      String.ends_with?(filename, "/minga_editor.ex")
  end
end

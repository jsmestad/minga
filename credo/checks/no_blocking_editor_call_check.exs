defmodule Minga.Credo.NoBlockingEditorCallCheck do
  @moduledoc """
  Flags synchronous blocking calls inside MingaEditor modules.

  MingaEditor is a single GenServer. Synchronous calls to LSP (`Client.request_sync`), shell commands (`System.cmd`), task awaits (`Task.await`), sleeps (`Process.sleep`), and synchronous reads into an Agent session (`MingaAgent.Session.editor_snapshot/1`, `messages/1`, `metadata/1` and the rest of `@session_reads`) make the Editor wait. When that wait happens in the Editor process it head-of-line-blocks input echo and rendering. Slow domain work should use a typed `EffectScheduler` request or a supervised Task instead, and session state should arrive through the session's events.

  Calls nested inside `Task.start`/`Task.start_link`/`Task.async` bodies are exempt because the work is already off the critical path.

  ## Session aliases

  Session reads match on the module after alias resolution. The check collects the `alias` declarations in the file (`alias MingaAgent.Session`, `alias MingaAgent.Session, as: AgentSession`, and `alias MingaAgent.{Message, Session}`) and expands the first segment of each remote call through them. Resolution is per file, not lexical: an alias declared in one module of a file applies to every call in that file. The check does not follow `import`, `__MODULE__`-relative aliases, or a session module reached through a variable or `apply/3`.

  ## Inline justification

  Each sanctioned call carries `# minga:allow-blocking — <justification>`, either on the same line as the call or in the comment lines directly above it. `mix format` moves a trailing comment onto its own line above the expression, so the line-above form is the one that survives formatting. The justification after the dash is required; a bare `# minga:allow-blocking` without explanation does not suppress. Exceptions live on the call they excuse and move with it; there is no line-numbered exception list.

  ## What this check is

  This check is a tripwire for new calls. It matches syntactic call tokens in one file. A blocking call reached through a helper or another module (e.g. `format_and_replace/3` calling `Minga.Editing.format/2` which calls `System.cmd`) is invisible to it, as is any `GenServer.call` outside the listed functions. Code without findings can still block the Editor. Per-site review is the isolation guarantee; this check makes sure new direct waits are seen in review.

  See responsiveness epic #2445 (D2/D3) and #3645 for the rationale.
  """

  use Credo.Check,
    id: "EX9008",
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      `Client.request_sync`, `System.cmd`, `Task.await`, `Process.sleep`, and synchronous `MingaAgent.Session` reads block the calling process. Inside MingaEditor modules these can block the single editor GenServer, causing head-of-line blocking for input echo and rendering.

      Use a typed `EffectScheduler` request or a supervised Task to move slow work off the critical path, or consume the session's events instead of reading its state.

      To justify a sanctioned call, add `# minga:allow-blocking — <justification>` on the same line or in the comment lines directly above it.
      """
    ]

  @blocking_calls [
    {[:Client], :request_sync},
    {[:Minga, :LSP, :Client], :request_sync},
    {[:System], :cmd},
    {[:Task], :await},
    {[:Process], :sleep}
  ]

  @session_module [:MingaAgent, :Session]

  # Public MingaAgent.Session functions that make the caller wait on a GenServer.call to read session state. load_session, import_legacy_session and subscribe also mutate, but the Editor calls them as part of reading a session in.
  @session_reads [
    :changed_file_counts,
    :check_inference_route,
    :discover_available_models,
    :editor_snapshot,
    :get_available_models,
    :get_provider,
    :import_legacy_session,
    :inference_route_setups,
    :list_branches,
    :list_skills,
    :list_tool_trust,
    :load_session,
    :messages,
    :messages_with_ids,
    :metadata,
    :model_selection,
    :pending_question,
    :pinned_ids,
    :queued_input_summaries,
    :queued_input_text,
    :read_cumulative_file_change,
    :read_draft_attachment,
    :read_retained_output,
    :session_id,
    :status,
    :subscribe,
    :subscriber_role,
    :transcript_history_before,
    :transcript_since,
    :usage
  ]

  @exempt_wrappers [
    {[:Task], :start},
    {[:Task], :start_link},
    {[:Task], :async}
  ]

  @type_attributes [:spec, :type, :typep, :opaque, :callback, :macrocallback]

  @suppression_pattern ~r/# minga:allow-blocking\s+—\s+\S/
  @comment_line_pattern ~r/^\s*#/

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      ast = SourceFile.ast(source_file)
      source_lines = source_file |> SourceFile.source() |> String.split("\n")
      ctx = %{issue_meta: issue_meta, aliases: collect_aliases(ast)}

      ast
      |> find_blocking_calls(ctx, false)
      |> Enum.reject(&suppressed_by_comment?(source_lines, &1))
    end
  end

  # ── Alias collection ──────────────────────────────────────────────────

  defp collect_aliases(ast) do
    {_ast, aliases} = Macro.prewalk(ast, %{}, &collect_alias/2)
    aliases
  end

  defp collect_alias({:alias, _, [{:__aliases__, _, parts} | opts]} = node, acc)
       when is_list(parts) do
    {node, put_alias(acc, parts, alias_name(parts, opts))}
  end

  defp collect_alias(
         {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _]} = node,
         acc
       )
       when is_list(base) and is_list(children) do
    acc =
      Enum.reduce(children, acc, fn
        {:__aliases__, _, suffix}, inner when is_list(suffix) ->
          put_alias(inner, base ++ suffix, List.last(suffix))

        _other, inner ->
          inner
      end)

    {node, acc}
  end

  defp collect_alias(node, acc), do: {node, acc}

  defp alias_name(parts, [opts]) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [name]} -> name
      _ -> List.last(parts)
    end
  end

  defp alias_name(parts, _opts), do: List.last(parts)

  defp put_alias(acc, parts, name) when is_atom(name) do
    if Enum.all?(parts, &is_atom/1), do: Map.put(acc, name, parts), else: acc
  end

  defp put_alias(acc, _parts, _name), do: acc

  defp resolve([head | rest] = mod_parts, aliases) do
    case Map.fetch(aliases, head) do
      {:ok, full} -> full ++ rest
      :error -> mod_parts
    end
  end

  defp resolve(mod_parts, _aliases), do: mod_parts

  # ── Traversal ─────────────────────────────────────────────────────────

  defp find_blocking_calls(ast, ctx, exempt?) do
    case ast do
      # Typespecs name remote types such as `Session.metadata()` with call syntax; they never run.
      {:@, _, [{attr, _, _}]} when attr in @type_attributes ->
        []

      # Pipe into an exempt Task wrapper.
      {:|>, meta, [_lhs, {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, args}]}
      when is_list(args) ->
        if exempt_wrapper?(mod_parts, func) do
          exempt_args_issues(args, ctx)
        else
          issues_for_node(mod_parts, func, meta, ctx, exempt?) ++
            children_issues(args, ctx, exempt?)
        end

      # Direct call to an exempt Task wrapper.
      {{:., _, [{:__aliases__, _, mod_parts}, func]}, meta, args} when is_list(args) ->
        if exempt_wrapper?(mod_parts, func) do
          exempt_args_issues(args, ctx)
        else
          issues_for_node(mod_parts, func, meta, ctx, exempt?) ++
            children_issues(args, ctx, exempt?)
        end

      # fn -> ... end (anonymous function body)
      {:fn, _meta, clauses} when is_list(clauses) ->
        Enum.flat_map(clauses, fn clause -> find_blocking_calls(clause, ctx, exempt?) end)

      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.flat_map(fn child -> find_blocking_calls(child, ctx, exempt?) end)

      list when is_list(list) ->
        Enum.flat_map(list, fn child -> find_blocking_calls(child, ctx, exempt?) end)

      _ ->
        []
    end
  end

  defp exempt_args_issues(args, ctx) do
    Enum.flat_map(args, fn arg -> find_blocking_calls(arg, ctx, true) end)
  end

  defp issues_for_node(mod_parts, func, meta, ctx, false = _exempt?) do
    if blocking_call?(mod_parts, resolve(mod_parts, ctx.aliases), func) do
      trigger = Enum.map_join(mod_parts, ".", &Atom.to_string/1) <> ".#{func}"

      [
        format_issue(ctx.issue_meta,
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

  defp issues_for_node(_mod_parts, _func, _meta, _ctx, true = _exempt?), do: []

  defp children_issues(args, ctx, exempt?) do
    Enum.flat_map(args, fn arg -> find_blocking_calls(arg, ctx, exempt?) end)
  end

  defp blocking_call?(_mod_parts, @session_module, func) when func in @session_reads, do: true

  defp blocking_call?(mod_parts, _resolved, func) do
    Enum.any?(@blocking_calls, fn {expected_parts, expected_func} ->
      func == expected_func && mod_parts == expected_parts
    end)
  end

  defp exempt_wrapper?(mod_parts, func) do
    Enum.any?(@exempt_wrappers, fn {expected_parts, expected_func} ->
      func == expected_func && mod_parts == expected_parts
    end)
  end

  # ── Justification ─────────────────────────────────────────────────────

  defp suppressed_by_comment?(source_lines, issue) do
    line_index = (issue.line_no || 0) - 1

    case Enum.at(source_lines, line_index) do
      nil -> false
      line -> justified?(line) or justified_above?(source_lines, line_index - 1)
    end
  end

  # Walks the contiguous comment-only lines directly above the call.
  defp justified_above?(_source_lines, index) when index < 0, do: false

  defp justified_above?(source_lines, index) do
    line = Enum.at(source_lines, index)

    cond do
      not Regex.match?(@comment_line_pattern, line) -> false
      justified?(line) -> true
      true -> justified_above?(source_lines, index - 1)
    end
  end

  defp justified?(line), do: Regex.match?(@suppression_pattern, line)

  # ── Scope ─────────────────────────────────────────────────────────────

  @supervisor_modules [
    "lib/minga_editor/frontend/resolve.ex"
  ]

  defp skip_file?(%SourceFile{} = source_file) do
    filename = Path.expand(source_file.filename)

    not editor_layer?(filename) or
      String.contains?(filename, "/test/") or
      supervisor_context?(source_file)
  end

  defp editor_layer?(filename) do
    String.contains?(filename, "/minga_editor/") or String.ends_with?(filename, "/minga_editor.ex")
  end

  defp supervisor_context?(%SourceFile{} = source_file) do
    rel_path = source_file.filename |> Path.expand() |> project_relative_path()
    rel_path in @supervisor_modules
  end

  defp project_relative_path(abs_path) do
    project_root = File.cwd!()

    case Path.relative_to(abs_path, project_root) do
      ^abs_path -> abs_path
      rel -> rel
    end
  end
end

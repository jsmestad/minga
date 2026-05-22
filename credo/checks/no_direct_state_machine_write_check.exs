defmodule Minga.Credo.NoDirectStateMachineWriteCheck do
  @moduledoc """
  Forbids direct writes to state machine fields on structs. Use the
  designated gate function instead.

  ## Why this exists

  State machine transitions should flow through a single gate function
  so we have one place to add validation, logging, and telemetry. When
  mode changes are scattered as raw struct updates across 20+ files,
  there's no single point of control and bypass sites are the most
  likely source of bugs.

  ## What this checks

  By default, this check flags any map update that sets the `mode:` key
  (e.g. `%{vim | mode: :normal, ...}` or `%{state | vim: %{... | mode: ...}}`).
  This catches the pattern where code bypasses `VimState.transition/3`
  or `EditorState.transition_mode/3`.

  The check is configurable via the `:gated_fields` parameter so it can
  be extended to other state machine fields in the future.

  ## What to do instead

      # Bad: bypasses the gate
      %{state | vim: %{state.vim | mode: :normal, mode_state: Mode.initial_state()}}

      # Good: goes through the gate
      EditorState.transition_mode(state, :normal)

  ## Exceptions

  This check ignores:
  - Files listed in `:allowed_files` (where the gate function lives)
  - `defstruct` expressions (struct definitions legitimately set defaults)
  - Test files (tests may construct structs directly)
  """

  use Credo.Check,
    id: "EX9004",
    base_priority: :normal,
    category: :design,
    param_defaults: [
      gated_fields: [:mode],
      guarded_struct_fields: [
        # VimState fields: must use VimState.set_*/transition instead of direct writes
        {:editing, [:mode_state, :marks, :last_jump_pos, :last_find_char, :macro_recorder, :change_recorder, :reg]},
        # Session.State fields: must use SessionState.set_* instead of direct writes
        {:workspace, [:keymap_scope, :completion, :completion_trigger, :highlight, :mouse, :document_highlights, :search, :lsp_pending, :viewport, :windows, :buffers, :agent_ui, :injection_ranges, :editing]}
      ],
      allowed_files: ["vim_state.ex", "state.ex", "session/state.ex"]
    ],
    explanations: [
      check: """
      State machine fields must be changed through their designated gate
      function, not via raw struct updates. This ensures all transitions
      flow through a single point where validation, logging, and telemetry
      can be added.

      Use `EditorState.transition_mode(state, mode)` or
      `VimState.transition(vim, mode)` instead of setting `mode:` directly.

      Use `SessionState.set_completion(ws, completion)` instead of
      `%{ws | completion: completion}`.
      """,
      params: [
        gated_fields: "List of field atoms to flag when set in map updates.",
        guarded_struct_fields: "List of {parent_field, [child_fields]} tuples for nested struct checks.",
        allowed_files: "Filename suffixes where direct writes are permitted (gate function homes)."
      ]
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file, params) do
      []
    else
      gated_fields = Params.get(params, :gated_fields, __MODULE__)
      guarded_struct_fields = Params.get(params, :guarded_struct_fields, __MODULE__)
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(
        &find_direct_writes(&1, &2, issue_meta, gated_fields, guarded_struct_fields)
      )
      |> List.flatten()
    end
  end

  # Match map update syntax: %{... | field: value, ...}
  # The AST for `%{map | key: val}` is:
  #   {:%{}, meta, [{:|, _, [map, [key: val]]}]}
  # We look for gated field names in the keyword list after the pipe.
  defp find_direct_writes(
         {:%{}, _meta, [{:|, _, [map, updates]}]} = ast,
         issues,
         issue_meta,
         gated_fields,
         guarded_struct_fields
       )
       when is_list(updates) do
    new_issues =
      direct_gated_field_issues(ast, updates, issue_meta, gated_fields) ++
        guarded_map_update_issues(ast, map, updates, issue_meta, guarded_struct_fields)

    {ast, new_issues ++ issues}
  end

  defp find_direct_writes(
         {:put_in, meta, [path_ast, _value]} = ast,
         issues,
         issue_meta,
         _gated_fields,
         guarded_struct_fields
       ) do
    new_issues =
      case guarded_path_match(extract_dot_path(path_ast), guarded_struct_fields) do
        nil ->
          []

        {parent, child} ->
          [
            format_issue(issue_meta,
              message:
                "Direct put_in through `#{parent}.#{child}` bypasses the owning state module. " <>
                  "Use the appropriate SessionState and sub-state setter instead.",
              trigger: "put_in",
              line_no: meta[:line] || extract_line(ast)
            )
          ]
      end

    {ast, new_issues ++ issues}
  end

  defp find_direct_writes(ast, issues, _issue_meta, _gated_fields, _guarded_struct_fields) do
    {ast, issues}
  end

  @spec direct_gated_field_issues(term(), keyword(), IssueMeta.t(), [atom()]) :: [Credo.Issue.t()]
  defp direct_gated_field_issues(ast, updates, issue_meta, gated_fields) do
    updates
    |> Enum.filter(fn
      {field, _value} when is_atom(field) -> field in gated_fields
      _ -> false
    end)
    |> Enum.map(fn {field, value} ->
      line_no = extract_line(value) || extract_line(ast)

      format_issue(issue_meta,
        message:
          "Direct write to `#{field}:` bypasses the state machine gate function. " <>
            "Use EditorState.transition_mode/3 or VimState.transition/3 instead.",
        trigger: "#{field}:",
        line_no: line_no
      )
    end)
  end

  @spec guarded_map_update_issues(term(), term(), keyword(), IssueMeta.t(), keyword([atom()])) :: [Credo.Issue.t()]
  defp guarded_map_update_issues(ast, map, updates, issue_meta, guarded_struct_fields) do
    map_path = extract_dot_path(map)
    map_match = guarded_path_match(map_path, guarded_struct_fields)

    updates
    |> Enum.flat_map(fn
      {field, value} when is_atom(field) ->
        update_match = guarded_path_match(map_path ++ [field], guarded_struct_fields)
        guarded_issue(ast, value, issue_meta, map_match || update_match, field)

      _ ->
        []
    end)
  end

  @spec guarded_issue(term(), term(), IssueMeta.t(), {atom(), atom()} | nil, atom()) :: [Credo.Issue.t()]
  defp guarded_issue(_ast, _value, _issue_meta, nil, _field), do: []

  defp guarded_issue(ast, value, issue_meta, {parent, child}, field) do
    [
      format_issue(issue_meta,
        message:
          "Direct write through `#{parent}.#{child}` bypasses the owning state module. " <>
            "Use the appropriate SessionState and sub-state setter instead.",
        trigger: "#{field}:",
        line_no: extract_line(value) || extract_line(ast)
      )
    ]
  end

  defp guarded_path_match(path, guarded_struct_fields) when is_list(path) do
    guarded_struct_fields
    |> Enum.find_value(fn {parent, children} ->
      path
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_value(fn
        [^parent, child] -> if child in children, do: {parent, child}
        _ -> nil
      end)
    end)
  end

  defp guarded_path_match(_path, _guarded_struct_fields), do: nil

  defp extract_dot_path({{:., _, [left, field]}, _, []}) when is_atom(field) do
    extract_dot_path(left) ++ [field]
  end

  defp extract_dot_path({name, _, context}) when is_atom(name) and is_atom(context), do: [name]
  defp extract_dot_path(_ast), do: []

  # Extracts line number from AST nodes with metadata.
  defp extract_line({_, meta, _}) when is_list(meta), do: meta[:line]
  defp extract_line(_), do: nil

  defp skip_file?(%SourceFile{} = source_file, params) do
    filename = Path.expand(source_file.filename)
    allowed = Params.get(params, :allowed_files, __MODULE__)

    String.contains?(filename, "/test/") or
      Enum.any?(allowed, fn suffix -> String.ends_with?(filename, suffix) end)
  end
end

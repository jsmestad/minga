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
      allowed_files: ["vim_state.ex", "state.ex"]
    ],
    explanations: [
      check: """
      State machine fields must be changed through their designated gate
      function, not via raw struct updates. This ensures all transitions
      flow through a single point where validation, logging, and telemetry
      can be added.

      Use `EditorState.transition_mode(state, mode)` or
      `VimState.transition(vim, mode)` instead of setting `mode:` directly.
      """,
      params: [
        gated_fields: "List of field atoms to flag when set in map updates.",
        allowed_files: "Filename suffixes where direct writes are permitted (gate function homes)."
      ]
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file, params) do
      []
    else
      gated_fields = Params.get(params, :gated_fields, __MODULE__)
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&find_direct_writes(&1, &2, issue_meta, gated_fields))
      |> List.flatten()
    end
  end

  # Match map update syntax: %{... | field: value, ...}
  # The AST for `%{map | key: val}` is:
  #   {:%{}, meta, [{:|, _, [map, [key: val]]}]}
  # We look for gated field names in the keyword list after the pipe.
  defp find_direct_writes(
         {:%{}, _meta, [{:|, _, [_map, updates]}]} = ast,
         issues,
         issue_meta,
         gated_fields
       )
       when is_list(updates) do
    new_issues =
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
      |> Enum.reject(&is_nil/1)

    {ast, new_issues ++ issues}
  end

  # Also catch nested map updates where the value itself is a map update
  # containing the gated field. E.g.:
  #   %{state | vim: %{state.vim | mode: :normal}}
  # The outer update has `vim:` whose value is another map update with `mode:`.
  defp find_direct_writes(ast, issues, _issue_meta, _gated_fields) do
    {ast, issues}
  end

  # Extracts line number from various AST shapes.
  defp extract_line({_, meta, _}) when is_list(meta), do: meta[:line]
  defp extract_line({:%{}, meta, _}) when is_list(meta), do: meta[:line]
  defp extract_line(_), do: nil

  defp skip_file?(%SourceFile{} = source_file, params) do
    filename = Path.expand(source_file.filename)
    allowed = Params.get(params, :allowed_files, __MODULE__)

    String.contains?(filename, "/test/") or
      Enum.any?(allowed, fn suffix -> String.ends_with?(filename, suffix) end)
  end
end

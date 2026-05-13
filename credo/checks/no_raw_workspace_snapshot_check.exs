defmodule Minga.Credo.NoRawWorkspaceSnapshotCheck do
  @moduledoc """
  Forbids `Map.from_struct/1` on workspace structs. Use `TabContext.from_workspace/1` instead.

  ## Why this exists

  `Map.from_struct(workspace)` produces a bare map that strips the struct
  tag and loses compile-time key checking. Code that snapshots a workspace
  this way silently breaks whenever a field is added or removed from
  `WorkspaceState`, because the intermediate map has no contract.

  Issue #1592 replaced the last `Map.from_struct(workspace)` call site with
  `TabContext.from_workspace/1`, which constructs the snapshot struct
  directly from the workspace fields. This check prevents the fragile
  intermediate-map pattern from being reintroduced.

  ## What this checks

  Any call to `Map.from_struct(arg)` where `arg` looks workspace-related:
  - A variable named `workspace` or `ws`
  - A dot access ending in `.workspace` (e.g., `state.workspace`)

  ## What to do instead

      # Bad: loses struct tag, silently breaks on field changes
      map = Map.from_struct(workspace)

      # Good: type-safe, explicit field selection
      context = TabContext.from_workspace(workspace)

  ## Exceptions

  - Test files are skipped
  - Modules listed in the `:allowed_files` param are skipped
  """

  use Credo.Check,
    id: "EX9006",
    base_priority: :normal,
    category: :design,
    param_defaults: [
      allowed_files: []
    ],
    explanations: [
      check: """
      Use `TabContext.from_workspace/1` instead of `Map.from_struct` on
      workspace structs. The intermediate map loses the struct tag and
      silently breaks when WorkspaceState fields change. See #1403.
      """,
      params: [
        allowed_files:
          "Filename suffixes or path fragments where Map.from_struct on workspace is permitted."
      ]
    ]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file, params) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&find_raw_workspace_snapshot(&1, &2, issue_meta))
      |> List.flatten()
    end
  end

  # Match `Map.from_struct(arg)` where arg is workspace-related
  defp find_raw_workspace_snapshot(
         {{:., _, [{:__aliases__, _, [:Map]}, :from_struct]}, meta, [arg]} = ast,
         issues,
         issue_meta
       ) do
    if workspace_arg?(arg) do
      issue =
        format_issue(issue_meta,
          message:
            "Use TabContext.from_workspace/1 instead of Map.from_struct on workspace structs. See #1403.",
          trigger: "Map.from_struct",
          line_no: meta[:line]
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp find_raw_workspace_snapshot(ast, issues, _issue_meta), do: {ast, issues}

  # Variable named :workspace or :ws
  defp workspace_arg?({name, _, _}) when name in [:workspace, :ws], do: true

  # Dot access ending in .workspace (e.g., state.workspace, s.workspace)
  defp workspace_arg?({{:., _, [_, :workspace]}, _, _}), do: true

  defp workspace_arg?(_), do: false

  defp skip_file?(%SourceFile{} = source_file, params) do
    filename = Path.expand(source_file.filename)
    allowed = Params.get(params, :allowed_files, __MODULE__)

    String.contains?(filename, "/test/") or
      Enum.any?(allowed, fn suffix -> String.contains?(filename, suffix) end)
  end
end

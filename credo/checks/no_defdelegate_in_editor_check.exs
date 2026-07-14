defmodule Minga.Credo.NoDelegateInEditorCheck do
  @moduledoc """
  Flags `defdelegate` calls inside `lib/minga_editor/` modules.

  Per project convention, callers should be updated directly instead of maintaining forwarding stubs. `defdelegate` preserves interfaces nobody asked for and makes you look in two places to understand one thing.

  This check is informational (refactor/design category). It tracks cleanup debt, not a hard block.
  """

  use Credo.Check,
    id: "EX9010",
    base_priority: :low,
    category: :refactor,
    explanations: [
      check: """
      `defdelegate` in editor modules creates forwarding stubs that preserve interfaces nobody asked for. Update callers directly instead of maintaining indirection.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&find_defdelegate(&1, &2, issue_meta))
      |> List.flatten()
    end
  end

  defp find_defdelegate({:defdelegate, meta, _args} = ast, issues, issue_meta) do
    issue =
      format_issue(issue_meta,
        message:
          "defdelegate creates a forwarding stub. Update callers directly instead of maintaining indirection.",
        trigger: "defdelegate",
        line_no: meta[:line]
      )

    {ast, [issue | issues]}
  end

  defp find_defdelegate(ast, issues, _issue_meta), do: {ast, issues}

  defp skip_file?(%SourceFile{} = source_file) do
    filename = Path.expand(source_file.filename)
    not String.contains?(filename, "/minga_editor/") or String.contains?(filename, "/test/")
  end
end

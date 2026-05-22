defmodule Minga.Credo.NoDirectModalOverlayWriteCheck do
  @moduledoc """
  Forbids direct writes to the modal overlay field. Use `MingaEditor.State.ModalOverlay` instead.

  The modal overlay is a tagged union with a single write gate. Raw map updates like `%{shell_state | modal: ...}` bypass the replacement policy and make it easy to reintroduce independent nullable modal state.

  This check flags map or struct updates that write `modal:` outside the small set of modules that own the gate and shell state structs.
  """

  use Credo.Check,
    id: "EX9005",
    base_priority: :normal,
    category: :design,
    param_defaults: [
      allowed_files: [
        "lib/minga_editor/state/modal_overlay.ex",
        "lib/minga_editor/shell/traditional/state.ex",
        "lib/minga_editor/shell/board/state.ex",
        "test/support/"
      ]
    ],
    explanations: [
      check: """
      Modal overlay writes must flow through `MingaEditor.State.ModalOverlay`.
      Use `ModalOverlay.open/3`, `transition/3`, `close/1`, or `dismiss/1` instead of raw `%{state | modal: ...}` updates.
      """,
      params: [
        allowed_files:
          "Filename suffixes or path fragments where direct modal writes are permitted."
      ]
    ]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    if allowed_file?(source_file, params) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&find_modal_writes(&1, &2, issue_meta))
      |> List.flatten()
    end
  end

  defp find_modal_writes({:%{}, _meta, [{:|, _, [_map, updates]}]} = ast, issues, issue_meta)
       when is_list(updates) do
    new_issues =
      updates
      |> Enum.filter(fn
        {:modal, _value} -> true
        _ -> false
      end)
      |> Enum.map(fn {:modal, value} ->
        line_no = extract_line(value) || extract_line(ast)

        format_issue(issue_meta,
          message:
            "Direct write to `modal:` bypasses MingaEditor.State.ModalOverlay. " <>
              "Use ModalOverlay.open/3, transition/3, close/1, or dismiss/1 instead.",
          trigger: "modal:",
          line_no: line_no
        )
      end)

    {ast, new_issues ++ issues}
  end

  defp find_modal_writes(ast, issues, _issue_meta), do: {ast, issues}

  defp extract_line({_, meta, _}) when is_list(meta), do: meta[:line]
  defp extract_line(_), do: nil

  defp allowed_file?(%SourceFile{} = source_file, params) do
    filename = Path.expand(source_file.filename)
    allowed = Params.get(params, :allowed_files, __MODULE__)

    Enum.any?(allowed, fn allowed_path -> String.contains?(filename, allowed_path) end)
  end
end

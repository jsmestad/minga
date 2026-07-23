defmodule MingaEditor.InlineEdit.Render do
  @moduledoc """
  Renders inline edits as transient block decorations.

  This is the edit variant adapter over the shared
  `MingaEditor.InlineOverlay.Render` framework: it supplies the
  edit-specific spec (group, glyph, diff body, footer, faces) and the
  store accessor, and delegates layout to the framework.
  """

  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias MingaEditor.InlineOverlay.Render, as: Overlay
  alias MingaEditor.State.InlineEdit

  @group :inline_edit

  @doc "Merges inline edit block decorations for a buffer into existing decorations."
  @spec merge_decorations(Decorations.t(), term(), pid() | nil) :: Decorations.t()
  def merge_decorations(%Decorations{} = decorations, state, buffer_pid)
      when is_pid(buffer_pid) do
    edit = state |> inline_edits() |> InlineEdit.active(buffer_pid)
    Overlay.merge_decorations(decorations, edit, spec())
  end

  def merge_decorations(%Decorations{} = decorations, _state, _buffer_pid), do: decorations

  @spec spec() :: Overlay.spec()
  defp spec do
    %{
      group: @group,
      priority: 1001,
      anchor_line: &elem(&1.selection_range, 1),
      prompt_glyph: "✎ ",
      prompt: & &1.prompt,
      header: &InlineEdit.header/1,
      input?: &InlineEdit.input?/1,
      body_lines: &body_lines/2,
      footer: &footer_text/1,
      face: &face/1
    }
  end

  @spec body_lines(InlineEdit.t(), pos_integer()) :: [{String.t(), atom()}]
  defp body_lines(%InlineEdit{phase: :input}, _content_width), do: []

  defp body_lines(%InlineEdit{phase: {:running, _session_pid, _proposal}}, _content_width),
    do: [{"… thinking", :body}]

  defp body_lines(%InlineEdit{} = edit, content_width) do
    removed = edit.original_text |> String.split("\n") |> Enum.map(&{"- " <> &1, :remove})

    added =
      edit
      |> InlineEdit.rewrite()
      |> String.split("\n")
      |> Enum.map(&{"+ " <> &1, proposal_face(edit)})

    (removed ++ added)
    |> Enum.slice(edit.scroll, 10)
    |> Enum.map(fn {text, face} -> {String.slice(text, 0, content_width), face} end)
  end

  @spec footer_text(InlineEdit.t()) :: String.t()
  defp footer_text(%InlineEdit{phase: :input}), do: "╰─ Enter submit · Esc cancel"
  defp footer_text(%InlineEdit{phase: {:running, _session_pid, _proposal}}), do: "╰─ Esc cancel"
  defp footer_text(%InlineEdit{phase: {:failed, _message}}), do: "╰─ n/Esc dismiss"
  defp footer_text(%InlineEdit{}), do: "╰─ y/Enter accept · n/Esc reject"

  @spec proposal_face(InlineEdit.t()) :: atom()
  defp proposal_face(%InlineEdit{phase: {:failed, _message}}), do: :error
  defp proposal_face(%InlineEdit{}), do: :add

  @spec face(atom()) :: Face.t()
  defp face(:header), do: Face.new(fg: 0xC792EA, bold: true)
  defp face(:input), do: Face.new(fg: 0xFFFFFF)
  defp face(:body), do: Face.new(fg: 0xD0D0D0)
  defp face(:remove), do: Face.new(fg: 0xFF6B6B)
  defp face(:add), do: Face.new(fg: 0x98C379)
  defp face(:error), do: Face.new(fg: 0xFF6B6B, bold: true)
  defp face(:help), do: Face.new(fg: 0x808080)

  @spec inline_edits(term()) :: InlineEdit.store()
  defp inline_edits(%{shell_state: shell_state}),
    do: MingaEditor.Shell.Traditional.State.inline_edits(shell_state)

  defp inline_edits(%{shell_runtime: %{state: shell_state}}),
    do: MingaEditor.Shell.Traditional.State.inline_edits(shell_state)

  defp inline_edits(_state), do: %{}
end

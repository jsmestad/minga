defmodule MingaEditor.InlineEdit.Render do
  @moduledoc """
  Renders inline edits as transient block decorations.
  """

  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias MingaEditor.State.InlineEdit

  @group :inline_edit

  @doc "Merges inline edit block decorations for a buffer into existing decorations."
  @spec merge_decorations(Decorations.t(), term(), pid() | nil) :: Decorations.t()
  def merge_decorations(%Decorations{} = decorations, state, buffer_pid)
      when is_pid(buffer_pid) do
    edit = state |> inline_edits() |> InlineEdit.active(buffer_pid)

    case edit do
      %InlineEdit{} -> add_edit_block(decorations, edit)
      nil -> decorations
    end
  end

  def merge_decorations(%Decorations{} = decorations, _state, _buffer_pid), do: decorations

  @spec add_edit_block(Decorations.t(), InlineEdit.t()) :: Decorations.t()
  defp add_edit_block(%Decorations{} = decorations, %InlineEdit{} = edit) do
    {_id, decorations} =
      Decorations.add_block_decoration(decorations, elem(edit.selection_range, 1),
        placement: :below,
        height: :dynamic,
        priority: 1001,
        group: @group,
        render: fn width -> render_edit(edit, width) end
      )

    %{decorations | version: decorations.version + :erlang.phash2(edit)}
  end

  @spec render_edit(InlineEdit.t(), pos_integer()) :: [[{String.t(), Face.t()}]]
  defp render_edit(%InlineEdit{} = edit, width) do
    content_width = max(width - 4, 10)
    header = [line("╭─ " <> InlineEdit.header(edit), :header, width)]
    prompt = [line("│ ✎ " <> edit.prompt <> prompt_cursor(edit), :input, width)]
    body = body_lines(edit, content_width, width)
    footer = [line(footer_text(edit), :help, width)]
    header ++ prompt ++ body ++ footer
  end

  @spec body_lines(InlineEdit.t(), pos_integer(), pos_integer()) :: [[{String.t(), Face.t()}]]
  defp body_lines(%InlineEdit{status: :input}, _content_width, _width), do: []

  defp body_lines(%InlineEdit{status: :thinking}, _content_width, width),
    do: [line("│ … thinking", :body, width)]

  defp body_lines(%InlineEdit{} = edit, content_width, width) do
    removed = edit.original_text |> String.split("\n") |> Enum.map(&{"- " <> &1, :remove})

    added =
      edit.proposed_rewrite
      |> String.split("\n")
      |> Enum.map(&{"+ " <> &1, status_face(edit.status)})

    (removed ++ added)
    |> Enum.drop(edit.scroll)
    |> Enum.take(10)
    |> Enum.map(fn {text, face} ->
      line("│ " <> String.slice(text, 0, content_width), face, width)
    end)
  end

  @spec prompt_cursor(InlineEdit.t()) :: String.t()
  defp prompt_cursor(%InlineEdit{status: :input}), do: "█"
  defp prompt_cursor(%InlineEdit{}), do: ""

  @spec footer_text(InlineEdit.t()) :: String.t()
  defp footer_text(%InlineEdit{status: :input}), do: "╰─ Enter submit · Esc cancel"
  defp footer_text(%InlineEdit{status: :thinking}), do: "╰─ Esc cancel"
  defp footer_text(%InlineEdit{status: :error}), do: "╰─ n/Esc dismiss"
  defp footer_text(%InlineEdit{}), do: "╰─ y/Enter accept · n/Esc reject"

  @spec status_face(InlineEdit.status()) :: atom()
  defp status_face(:error), do: :error
  defp status_face(_status), do: :add

  @spec line(String.t(), atom(), pos_integer()) :: [{String.t(), Face.t()}]
  defp line(text, kind, width), do: [{String.slice(text, 0, width), face(kind)}]

  @spec face(atom()) :: Face.t()
  defp face(:header), do: Face.new(fg: 0xC792EA, bold: true)
  defp face(:input), do: Face.new(fg: 0xFFFFFF)
  defp face(:body), do: Face.new(fg: 0xD0D0D0)
  defp face(:remove), do: Face.new(fg: 0xFF6B6B)
  defp face(:add), do: Face.new(fg: 0x98C379)
  defp face(:error), do: Face.new(fg: 0xFF6B6B, bold: true)
  defp face(:help), do: Face.new(fg: 0x808080)

  @spec inline_edits(term()) :: InlineEdit.store()
  defp inline_edits(%{shell_state: %{inline_edits: edits}}) when is_map(edits), do: edits
  defp inline_edits(_state), do: %{}
end

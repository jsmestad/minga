defmodule MingaEditor.InlineOverlay.Render do
  @moduledoc """
  Shared rendering framework for inline overlays (ask and edit).

  Inline asks and inline edits are near-twins: each renders a transient
  block decoration anchored to a buffer line, with a header, a prompt
  line, a status-dependent body, and a footer. This module owns that
  common skeleton. The variant-specific pieces (group, priority, anchor,
  prompt glyph, body lines, footer text, and the face palette) are
  supplied as a `spec` map, so neither variant branches inside the call
  site.

  Variant adapters (`MingaEditor.InlineAsk.Render`,
  `MingaEditor.InlineEdit.Render`) provide the spec and the store
  accessor; this module does the layout.
  """

  alias Minga.Core.Decorations
  alias Minga.Core.Face

  @typedoc """
  Variant behaviour for an inline overlay renderer.

  * `:group` / `:priority` / `:anchor_line` configure the block decoration.
  * `:prompt_glyph` is the marker shown before the prompt text (`"? "`, `"✎ "`).
  * `:prompt` reads the in-progress prompt string off the overlay struct.
  * `:header` returns the header text (without the `╭─ ` border).
  * `:input?` is true while the overlay is still accepting prompt input
    (the prompt cursor blinks only then).
  * `:body_lines` returns the status-dependent body as `{text, face_kind}`
    tuples, already trimmed to `content_width`.
  * `:footer` returns the footer text (including the `╰─ ` border).
  * `:face` maps a face kind atom to a `Face.t()`.
  """
  @type spec :: %{
          group: atom(),
          priority: non_neg_integer(),
          anchor_line: (struct() -> non_neg_integer()),
          prompt_glyph: String.t(),
          prompt: (struct() -> String.t()),
          header: (struct() -> String.t()),
          input?: (struct() -> boolean()),
          body_lines: (struct(), pos_integer() -> [{String.t(), atom()}]),
          footer: (struct() -> String.t()),
          face: (atom() -> Face.t())
        }

  @doc """
  Merges an overlay block decoration for `overlay` into `decorations`.

  When `overlay` is `nil` the decorations are returned unchanged, which
  lets adapters pipe the active-overlay lookup straight in.
  """
  @spec merge_decorations(Decorations.t(), struct() | nil, spec()) :: Decorations.t()
  def merge_decorations(%Decorations{} = decorations, nil, _spec), do: decorations

  def merge_decorations(%Decorations{} = decorations, overlay, spec) when is_map(spec) do
    {_id, decorations} =
      Decorations.add_block_decoration(decorations, spec.anchor_line.(overlay),
        placement: :below,
        height: :dynamic,
        priority: spec.priority,
        group: spec.group,
        render: fn width -> render(overlay, width, spec) end
      )

    %{decorations | version: decorations.version + :erlang.phash2(overlay)}
  end

  @spec render(struct(), pos_integer(), spec()) :: [[{String.t(), Face.t()}]]
  defp render(overlay, width, spec) do
    content_width = max(width - 4, 10)
    header = [line("╭─ " <> spec.header.(overlay), :header, width, spec)]

    prompt = [
      line(
        "│ " <> spec.prompt_glyph <> spec.prompt.(overlay) <> cursor(overlay, spec),
        :input,
        width,
        spec
      )
    ]

    body = body(overlay, content_width, width, spec)
    footer = [line(spec.footer.(overlay), :help, width, spec)]
    header ++ prompt ++ body ++ footer
  end

  @spec body(struct(), pos_integer(), pos_integer(), spec()) :: [[{String.t(), Face.t()}]]
  defp body(overlay, content_width, width, spec) do
    overlay
    |> spec.body_lines.(content_width)
    |> Enum.map(fn {text, kind} -> line("│ " <> text, kind, width, spec) end)
  end

  @spec cursor(struct(), spec()) :: String.t()
  defp cursor(overlay, spec) do
    if spec.input?.(overlay), do: "█", else: ""
  end

  @spec line(String.t(), atom(), pos_integer(), spec()) :: [{String.t(), Face.t()}]
  defp line(text, kind, width, spec) do
    [{String.slice(text, 0, width), spec.face.(kind)}]
  end
end

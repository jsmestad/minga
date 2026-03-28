defmodule Minga.Editor.LspDecorations do
  @moduledoc """
  Applies LSP code lens and inlay hint data as buffer decorations.

  Converts the parsed LSP responses stored in editor state into virtual
  text decorations on the active buffer. Called after LSP responses arrive
  and on viewport changes (for inlay hints, which are viewport-scoped).

  Code lenses are rendered as dim virtual lines above functions (`:above`
  placement). Inlay hints are rendered as inline annotations (`:inline`
  placement) with subtle styling.
  """

  alias Minga.Buffer
  alias Minga.Core.Face

  @type state :: Minga.Editor.State.t()

  @doc """
  Applies code lens decorations to the active buffer.

  Removes any previous `:code_lens` group decorations and adds the
  current lenses as `:above` virtual text.
  """
  @spec apply_code_lenses(state()) :: state()
  def apply_code_lenses(%{workspace: %{buffers: %{active: nil}}} = state), do: state
  def apply_code_lenses(%{lsp: %{code_lenses: []}} = state), do: state

  def apply_code_lenses(
        %{workspace: %{buffers: %{active: buf}}, lsp: %{code_lenses: lenses}} = state
      ) do
    # Remove old code lens decorations
    Buffer.remove_highlight_group(buf, :code_lens)

    # Add new ones
    Enum.each(lenses, fn lens ->
      segments = [{lens.title, Face.new(fg: 0x6B7280, italic: true)}]

      Buffer.add_virtual_text(buf, {lens.line, 0},
        segments: segments,
        placement: :above,
        priority: -20,
        group: :code_lens
      )
    end)

    state
  end

  @doc """
  Applies inlay hint decorations to the active buffer.

  Removes any previous `:inlay_hint` group decorations and adds the
  current hints as `:inline` virtual text at their positions.
  """
  @spec apply_inlay_hints(state()) :: state()
  def apply_inlay_hints(%{workspace: %{buffers: %{active: nil}}} = state), do: state
  def apply_inlay_hints(%{lsp: %{inlay_hints: []}} = state), do: state

  def apply_inlay_hints(
        %{workspace: %{buffers: %{active: buf}}, lsp: %{inlay_hints: hints}} = state
      ) do
    # Remove old inlay hint decorations
    Buffer.remove_highlight_group(buf, :inlay_hint)

    # Add new ones
    Enum.each(hints, fn hint ->
      label = format_hint_label(hint)
      segments = [{label, Face.new(fg: 0x6B7280, italic: true)}]

      Buffer.add_virtual_text(buf, {hint.line, hint.col},
        segments: segments,
        placement: :inline,
        priority: -25,
        group: :inlay_hint
      )
    end)

    state
  end

  @spec format_hint_label(map()) :: String.t()
  defp format_hint_label(hint) do
    label = hint.label
    pad_left = if hint.padding_left, do: " ", else: ""
    pad_right = if hint.padding_right, do: " ", else: ""
    "#{pad_left}#{label}#{pad_right}"
  end
end

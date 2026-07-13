defmodule MingaEditor.InlineAsk.Render do
  @moduledoc """
  Renders inline asks as transient block decorations.

  This is the ask variant adapter over the shared
  `MingaEditor.InlineOverlay.Render` framework: it supplies the ask-specific
  spec (group, glyph, body, footer, faces) and the store accessor, and
  delegates layout to the framework.
  """

  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias MingaEditor.InlineOverlay.Render, as: Overlay
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.InlineAsk

  @group :inline_ask

  @doc "Merges inline ask block decorations for a buffer into existing decorations."
  @spec merge_decorations(Decorations.t(), term(), pid() | nil) :: Decorations.t()
  def merge_decorations(%Decorations{} = decorations, state, buffer_pid)
      when is_pid(buffer_pid) do
    ask = state |> inline_asks() |> InlineAsk.active(buffer_pid)
    Overlay.merge_decorations(decorations, ask, spec())
  end

  def merge_decorations(%Decorations{} = decorations, _state, _buffer_pid), do: decorations

  @doc "Returns true when the active buffer has an inline ask."
  @spec active?(term()) :: boolean()
  def active?(%{workspace: %{buffers: %{active: buffer_pid}}} = state) when is_pid(buffer_pid) do
    state |> inline_asks() |> InlineAsk.active(buffer_pid) != nil
  end

  def active?(_state), do: false

  @spec spec() :: Overlay.spec()
  defp spec do
    %{
      group: @group,
      priority: 1000,
      anchor_line: & &1.anchor_line,
      prompt_glyph: "? ",
      prompt: & &1.prompt,
      header: &InlineAsk.header/1,
      input?: &(&1.status == :input),
      body_lines: &response_lines/2,
      footer: fn _ask -> "╰─ Esc dismiss · Tab promote to workspace" end,
      face: &face/1
    }
  end

  @spec response_lines(InlineAsk.t(), pos_integer()) :: [{String.t(), atom()}]
  defp response_lines(%InlineAsk{status: :input}, _content_width), do: []

  defp response_lines(%InlineAsk{status: :thinking}, _content_width),
    do: [{"… thinking", :body}]

  defp response_lines(%InlineAsk{response: response, scroll: scroll}, content_width) do
    response
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, content_width))
    |> Enum.slice(scroll, 8)
    |> Enum.map(&{&1, :body})
  end

  @spec wrap_line(String.t(), pos_integer()) :: [String.t()]
  defp wrap_line("", _width), do: [""]

  defp wrap_line(text, width) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  @spec face(atom()) :: Face.t()
  defp face(:header), do: Face.new(fg: 0xC792EA, bold: true)
  defp face(:input), do: Face.new(fg: 0xFFFFFF)
  defp face(:body), do: Face.new(fg: 0xD0D0D0)
  defp face(:help), do: Face.new(fg: 0x808080)

  @spec inline_asks(term()) :: InlineAsk.store()
  defp inline_asks(state), do: AgentAccess.inline_asks(state)
end

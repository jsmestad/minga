defmodule MingaEditor.InlineAsk.Render do
  @moduledoc """
  Renders inline asks as transient block decorations.
  """

  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias MingaEditor.State.InlineAsk

  @group :inline_ask

  @doc "Merges inline ask block decorations for a buffer into existing decorations."
  @spec merge_decorations(Decorations.t(), term(), pid() | nil) :: Decorations.t()
  def merge_decorations(%Decorations{} = decorations, state, buffer_pid)
      when is_pid(buffer_pid) do
    ask = state |> inline_asks() |> InlineAsk.active(buffer_pid)

    case ask do
      %InlineAsk{} -> add_ask_block(decorations, ask)
      nil -> decorations
    end
  end

  def merge_decorations(%Decorations{} = decorations, _state, _buffer_pid), do: decorations

  @doc "Returns true when the active buffer has an inline ask."
  @spec active?(term()) :: boolean()
  def active?(%{workspace: %{buffers: %{active: buffer_pid}}} = state) when is_pid(buffer_pid) do
    state |> inline_asks() |> InlineAsk.active(buffer_pid) != nil
  end

  def active?(_state), do: false

  @spec add_ask_block(Decorations.t(), InlineAsk.t()) :: Decorations.t()
  defp add_ask_block(%Decorations{} = decorations, %InlineAsk{} = ask) do
    {_id, decorations} =
      Decorations.add_block_decoration(decorations, ask.anchor_line,
        placement: :below,
        height: :dynamic,
        priority: 1000,
        group: @group,
        render: fn width -> render_ask(ask, width) end
      )

    %{decorations | version: decorations.version + :erlang.phash2(ask)}
  end

  @spec render_ask(InlineAsk.t(), pos_integer()) :: [[{String.t(), Face.t()}]]
  defp render_ask(%InlineAsk{} = ask, width) do
    content_width = max(width - 4, 10)
    base = [line("╭─ " <> InlineAsk.header(ask), :header, width)]
    prompt = [line("│ ? " <> ask.prompt <> prompt_cursor(ask), :input, width)]
    body = response_lines(ask, content_width, width)
    footer = [line("╰─ Esc dismiss · Tab promote to workspace", :help, width)]
    base ++ prompt ++ body ++ footer
  end

  @spec response_lines(InlineAsk.t(), pos_integer(), pos_integer()) :: [[{String.t(), Face.t()}]]
  defp response_lines(%InlineAsk{status: :input}, _content_width, _width), do: []

  defp response_lines(%InlineAsk{status: :thinking}, _content_width, width),
    do: [line("│ … thinking", :body, width)]

  defp response_lines(%InlineAsk{response: response, scroll: scroll}, content_width, width) do
    response
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, content_width))
    |> Enum.drop(scroll)
    |> Enum.take(8)
    |> Enum.map(&line("│ " <> &1, :body, width))
  end

  @spec prompt_cursor(InlineAsk.t()) :: String.t()
  defp prompt_cursor(%InlineAsk{status: :input}), do: "█"
  defp prompt_cursor(%InlineAsk{}), do: ""

  @spec wrap_line(String.t(), pos_integer()) :: [String.t()]
  defp wrap_line("", _width), do: [""]

  defp wrap_line(text, width) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  @spec line(String.t(), atom(), pos_integer()) :: [{String.t(), Face.t()}]
  defp line(text, kind, width) do
    [{String.slice(text, 0, width), face(kind)}]
  end

  @spec face(atom()) :: Face.t()
  defp face(:header), do: Face.new(fg: 0xC792EA, bold: true)
  defp face(:input), do: Face.new(fg: 0xFFFFFF)
  defp face(:body), do: Face.new(fg: 0xD0D0D0)
  defp face(:help), do: Face.new(fg: 0x808080)

  @spec inline_asks(term()) :: InlineAsk.store()
  defp inline_asks(%{shell_state: %{inline_asks: asks}}) when is_map(asks), do: asks
  defp inline_asks(_state), do: %{}
end

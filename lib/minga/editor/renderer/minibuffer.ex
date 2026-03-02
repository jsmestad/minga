defmodule Minga.Editor.Renderer.Minibuffer do
  @moduledoc """
  Minibuffer (bottom status line) rendering: search prompt, command input,
  status messages, and the empty-state fallback.
  """

  alias Minga.Port.Protocol

  @doc "Renders the minibuffer at `row` with a max width of `cols`."
  @spec render(map(), non_neg_integer(), pos_integer()) :: binary()
  def render(%{mode: :search, mode_state: ms}, row, cols) do
    prefix = if ms.direction == :forward, do: "/", else: "?"
    search_text = prefix <> ms.input

    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(search_text, cols),
      fg: 0xEEEEEE,
      bg: 0x000000
    )
  end

  def render(%{mode: :search_prompt, mode_state: ms}, row, cols) do
    prompt_text = "Search: " <> ms.input

    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(prompt_text, cols),
      fg: 0xEEEEEE,
      bg: 0x000000
    )
  end

  def render(%{mode: :substitute_confirm, mode_state: ms}, row, cols) do
    current = ms.current + 1
    total = length(ms.matches)
    prompt = "replace with #{ms.replacement}? [y/n/a/q] (#{current} of #{total})"

    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(prompt, cols),
      fg: 0xEEEEEE,
      bg: 0x000000
    )
  end

  def render(%{mode: :command, mode_state: ms}, row, cols) do
    cmd_text = ":" <> ms.input

    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(cmd_text, cols),
      fg: 0xEEEEEE,
      bg: 0x000000
    )
  end

  def render(%{status_msg: msg}, row, cols) when is_binary(msg) do
    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(msg, cols),
      fg: 0xFFCC00,
      bg: 0x000000
    )
  end

  def render(_state, row, cols) do
    Protocol.encode_draw(
      row,
      0,
      String.duplicate(" ", cols),
      fg: 0x888888,
      bg: 0x000000
    )
  end
end

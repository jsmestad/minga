defmodule Minga.Editor.Renderer.Minibuffer do
  @moduledoc """
  Minibuffer (bottom status line) rendering: search prompt, command input,
  status messages, and the empty-state fallback.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Diagnostics
  alias Minga.Editor.LspBridge
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

  def render(%{mode: :eval, mode_state: ms}, row, cols) do
    eval_text = "Eval: " <> ms.input

    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(eval_text, cols),
      fg: 0xEEEEEE,
      bg: 0x000000
    )
  end

  def render(
        %{mode: :normal, mode_state: %{pending_describe_key: true, describe_key_keys: keys}},
        row,
        cols
      ) do
    prompt =
      case keys do
        [] -> "Press key to describe:"
        _ -> "Press key to describe: " <> (keys |> Enum.reverse() |> Enum.join(" ")) <> " …"
      end

    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(prompt, cols),
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

  def render(%{buf: %{buffer: buf}} = state, row, cols)
      when is_pid(buf) and state.mode in [:normal, :insert, :replace] do
    case cursor_line_diagnostic(buf) do
      nil ->
        render_blank(row, cols)

      msg ->
        Protocol.encode_draw(
          row,
          0,
          String.pad_trailing(msg, cols),
          fg: 0x888888,
          bg: 0x000000
        )
    end
  end

  def render(_state, row, cols), do: render_blank(row, cols)

  @spec render_blank(non_neg_integer(), pos_integer()) :: binary()
  defp render_blank(row, cols) do
    Protocol.encode_draw(
      row,
      0,
      String.duplicate(" ", cols),
      fg: 0x888888,
      bg: 0x000000
    )
  end

  @spec cursor_line_diagnostic(pid()) :: String.t() | nil
  defp cursor_line_diagnostic(buf) do
    file_path = BufferServer.file_path(buf)

    case file_path do
      nil ->
        nil

      path ->
        uri = LspBridge.path_to_uri(path)
        {cursor_line, _col} = BufferServer.cursor(buf)
        first_on_line(uri, cursor_line)
    end
  end

  @spec first_on_line(String.t(), non_neg_integer()) :: String.t() | nil
  defp first_on_line(uri, line) do
    uri
    |> Diagnostics.for_uri()
    |> Enum.find(fn d -> d.range.start_line == line end)
    |> case do
      nil -> nil
      diag -> format_hint(diag)
    end
  end

  @spec format_hint(Diagnostics.Diagnostic.t()) :: String.t()
  defp format_hint(diag) do
    icon = severity_icon(diag.severity)
    source = if diag.source, do: " [#{diag.source}]", else: ""
    "#{icon} #{diag.message}#{source}"
  end

  @spec severity_icon(Diagnostics.Diagnostic.severity()) :: String.t()
  defp severity_icon(:error), do: "✖"
  defp severity_icon(:warning), do: "⚠"
  defp severity_icon(:info), do: "ℹ"
  defp severity_icon(:hint), do: "💡"
end

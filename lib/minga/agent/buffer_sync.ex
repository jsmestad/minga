defmodule Minga.Agent.BufferSync do
  @moduledoc """
  Syncs agent conversation messages into a `*Agent*` BufferServer.

  Converts the session's message list into markdown text and writes
  it into the buffer. The buffer provides a vim-navigable view of
  the conversation, with tree-sitter markdown highlighting.
  """

  alias Minga.Agent.ChatDecorations
  alias Minga.Buffer.Server, as: BufferServer

  @doc """
  Starts the `*Agent*` buffer.

  Returns the buffer pid. The buffer is nofile (no save), read-only
  (no user edits), unlisted (hidden from buffer picker), and persistent
  (survives buffer kill).
  """
  @spec start_buffer() :: pid() | nil
  def start_buffer do
    case BufferServer.start_link(
           content: "",
           buffer_type: :nofile,
           buffer_name: "*Agent*",
           filetype: :markdown,
           read_only: true,
           unlisted: true,
           persistent: true
         ) do
      {:ok, pid} ->
        BufferServer.set_option(pid, :line_numbers, :none)
        # Word wrapping is desired but currently mutually exclusive with
        # DisplayMap (block decorations). Leave off until that interaction
        # is resolved. See render_pipeline/content.ex line ~135.
        # BufferServer.set_option(pid, :wrap, true)
        pid

      _ ->
        nil
    end
  end

  @doc """
  Syncs messages into the agent buffer as markdown text.

  Each message is rendered as a markdown section with a header.
  The buffer cursor is moved to the end (auto-scroll).
  """
  @spec sync(pid(), [term()], keyword()) :: :ok
  def sync(pid, messages, opts \\ []) do
    {text, line_offsets} = messages_to_markdown_with_offsets(messages)
    BufferServer.replace_content_force(pid, text)

    # Apply decorations using pre-computed line offsets (no re-derivation)
    try do
      agent_theme = Keyword.get(opts, :agent_theme, default_agent_theme())
      ChatDecorations.apply(pid, messages, line_offsets, agent_theme, opts)
    rescue
      e ->
        Minga.Log.error(
          :agent,
          "[buffer_sync] decoration apply failed: #{Exception.message(e)}"
        )
    end

    # Move cursor to end (auto-scroll)
    line_count = BufferServer.line_count(pid)
    BufferServer.move_to(pid, {max(line_count - 1, 0), 0})
    :ok
  end

  @doc false
  @spec messages_to_markdown_with_offsets([term()]) ::
          {String.t(), [ChatDecorations.line_offset()]}
  def messages_to_markdown_with_offsets(messages) do
    {parts, offsets, _line} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0}, fn {msg, idx}, {parts, offsets, line} ->
        md = message_to_markdown(msg)
        line_count = md |> String.split("\n") |> length()
        # "\n\n" join adds 1 empty line between messages
        separator_lines = if parts == [], do: 0, else: 1
        start = line + separator_lines

        {[md | parts], [{idx, start, line_count} | offsets], start + line_count}
      end)

    text = parts |> Enum.reverse() |> Enum.join("\n\n")
    {text, Enum.reverse(offsets)}
  end

  # Buffer text is content only. Visual headers (▎ You, ▎ Agent, ┌─ ✓ bash)
  # are rendered by block decorations in ChatDecorations, not by markdown.
  @spec message_to_markdown(term()) :: String.t()
  defp message_to_markdown({:user, text, _attachments}), do: message_to_markdown({:user, text})
  defp message_to_markdown({:user, text}), do: text
  defp message_to_markdown({:assistant, text}), do: text
  defp message_to_markdown({:thinking, text, _collapsed}), do: text

  defp message_to_markdown({:usage, %{input: i, output: o, cost: c}}) when is_integer(c) do
    "↑#{i} ↓#{o} $#{Float.round(c * 1.0, 3)}"
  end

  defp message_to_markdown({:usage, %{input: i, output: o, cost: c}}) when is_float(c) do
    "↑#{i} ↓#{o} $#{Float.round(c, 3)}"
  end

  defp message_to_markdown({:tool_call, tc}) do
    if tc.result != "" do
      String.slice(tc.result, 0, 500)
    else
      ""
    end
  end

  defp message_to_markdown(_other), do: ""

  defp default_agent_theme do
    theme = Minga.Theme.get!(Minga.Theme.default())
    Minga.Theme.agent_theme(theme)
  end
end

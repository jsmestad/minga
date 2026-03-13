defmodule Minga.Agent.BufferSync do
  @moduledoc """
  Syncs agent conversation messages into a `*Agent*` BufferServer.

  Converts the session's message list into markdown text and writes
  it into the buffer. The buffer provides a vim-navigable view of
  the conversation, with tree-sitter markdown highlighting.
  """

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
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  @doc """
  Syncs messages into the agent buffer as markdown text.

  Each message is rendered as a markdown section with a header.
  The buffer cursor is moved to the end (auto-scroll).
  """
  @spec sync(pid(), [term()]) :: :ok
  def sync(pid, messages) do
    text = messages_to_markdown(messages)
    BufferServer.replace_content_force(pid, text)

    # Move cursor to end (auto-scroll)
    line_count = BufferServer.line_count(pid)
    BufferServer.move_to(pid, {max(line_count - 1, 0), 0})
    :ok
  end

  @spec messages_to_markdown([term()]) :: String.t()
  defp messages_to_markdown(messages) do
    Enum.map_join(messages, "\n\n", &message_to_markdown/1)
  end

  @spec message_to_markdown(term()) :: String.t()
  defp message_to_markdown({:user, text, _attachments}) do
    message_to_markdown({:user, text})
  end

  defp message_to_markdown({:user, text}) do
    "## You\n\n#{text}"
  end

  defp message_to_markdown({:assistant, text}) do
    "## Agent\n\n#{text}"
  end

  defp message_to_markdown({:thinking, text, _collapsed}) do
    "> **Thinking**\n>\n> #{String.replace(text, "\n", "\n> ")}"
  end

  defp message_to_markdown({:usage, %{input: i, output: o, cost: c}}) when is_integer(c) do
    "*↑#{i} ↓#{o} $#{Float.round(c * 1.0, 3)}*"
  end

  defp message_to_markdown({:usage, %{input: i, output: o, cost: c}}) when is_float(c) do
    "*↑#{i} ↓#{o} $#{Float.round(c, 3)}*"
  end

  defp message_to_markdown({:tool_call, tc}) do
    status =
      case tc.status do
        :running -> "⟳"
        :complete -> "✓"
        :error -> "✗"
      end

    result_text =
      if tc.result != "" do
        "\n```\n#{String.slice(tc.result, 0, 500)}\n```"
      else
        ""
      end

    "### #{status} #{tc.name}\n#{result_text}"
  end

  defp message_to_markdown(_other), do: ""
end

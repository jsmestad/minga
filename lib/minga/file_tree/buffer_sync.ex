defmodule Minga.FileTree.BufferSync do
  @moduledoc """
  Syncs the FileTree data structure into a BufferServer.

  Converts visible tree entries to text lines and writes them into
  the buffer. The buffer cursor line maps 1:1 to the tree cursor index.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.FileTree

  @indent_size 2

  @doc """
  Starts a `*File Tree*` buffer and syncs tree entries into it.

  Returns the buffer pid.
  """
  @spec start_buffer(FileTree.t()) :: pid()
  def start_buffer(tree) do
    {:ok, pid} =
      BufferServer.start_link(
        content: "",
        buffer_type: :nofile,
        buffer_name: "*File Tree*",
        read_only: true,
        unlisted: true
      )

    sync(pid, tree)
    pid
  end

  @doc """
  Writes the visible tree entries into the buffer as text lines
  and moves the buffer cursor to match the tree cursor.
  """
  @spec sync(pid(), FileTree.t()) :: :ok
  def sync(pid, tree) do
    entries = FileTree.visible_entries(tree)
    text = entries_to_text(entries, tree.expanded)
    BufferServer.replace_content_force(pid, text)
    # Move buffer cursor to match tree cursor
    BufferServer.move_to(pid, {tree.cursor, 0})
    :ok
  end

  @doc """
  Converts tree entries to a single text string with newlines.
  Each entry becomes one line: indentation + icon + name.
  """
  @spec entries_to_text([FileTree.entry()], MapSet.t(String.t())) :: String.t()
  def entries_to_text(entries, expanded) do
    Enum.map_join(entries, "\n", fn entry -> entry_to_line(entry, expanded) end)
  end

  @spec entry_to_line(FileTree.entry(), MapSet.t(String.t())) :: String.t()
  defp entry_to_line(entry, expanded) do
    indent = String.duplicate(" ", entry.depth * @indent_size)
    is_expanded = entry.dir? and MapSet.member?(expanded, entry.path)

    icon =
      case {entry.dir?, is_expanded} do
        {true, true} -> "▾ "
        {true, false} -> "▸ "
        {false, _} -> "  "
      end

    indent <> icon <> entry.name
  end
end

defmodule Minga.FileTree.BufferSync do
  @moduledoc """
  Syncs the FileTree data structure into a BufferServer.

  Converts visible tree entries to text lines and writes them into
  the buffer. The buffer cursor line maps 1:1 to the tree cursor index.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Devicon
  alias Minga.FileTree
  alias Minga.Language.Filetype

  # Box-drawing characters matching TreeRenderer
  @guide_pipe "│ "
  @guide_tee "├─"
  @guide_elbow "└─"
  @guide_blank "  "

  # Nerd Font folder icons matching TreeRenderer
  @folder_closed "\u{F024B}"
  @folder_open "\u{F0256}"

  @doc """
  Starts a `*File Tree*` buffer and syncs tree entries into it.

  Returns the buffer pid.
  """
  @spec start_buffer(FileTree.t()) :: pid() | nil
  def start_buffer(tree) do
    pid =
      case BufferServer.start_link(
             content: "",
             buffer_type: :nofile,
             buffer_name: "*File Tree*",
             read_only: true,
             unlisted: true
           ) do
        {:ok, p} -> p
        _ -> nil
      end

    if pid, do: sync(pid, tree)
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
  Each entry becomes one line: guides + icon + name.
  """
  @spec entries_to_text([FileTree.entry()], MapSet.t(String.t())) :: String.t()
  def entries_to_text(entries, expanded) do
    Enum.map_join(entries, "\n", fn entry -> entry_to_line(entry, expanded) end)
  end

  @spec entry_to_line(FileTree.entry(), MapSet.t(String.t())) :: String.t()
  defp entry_to_line(entry, expanded) do
    guides = build_guides(entry.guides, entry.last_child?)
    is_expanded = entry.dir? and MapSet.member?(expanded, entry.path)

    icon =
      case {entry.dir?, is_expanded} do
        {true, true} -> @folder_open
        {true, false} -> @folder_closed
        {false, _} -> Devicon.icon(Filetype.detect(entry.path))
      end

    name = if entry.dir?, do: entry.name <> "/", else: entry.name

    guides <> icon <> " " <> name
  end

  @spec build_guides([boolean()], boolean()) :: String.t()
  defp build_guides(ancestor_guides, last_child?) do
    ancestor_part =
      Enum.map_join(ancestor_guides, fn
        true -> @guide_pipe
        false -> @guide_blank
      end)

    connector = if last_child?, do: @guide_elbow, else: @guide_tee

    ancestor_part <> connector
  end
end

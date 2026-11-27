defmodule Minga.Project.FileTree.BufferSync do
  @moduledoc """
  Syncs the FileTree data structure into a Buffer.

  Converts visible tree entries to text lines and writes them into
  the buffer. The buffer cursor line maps 1:1 to the tree cursor index.
  """

  alias Minga.Buffer
  alias Minga.Language
  alias Minga.Project.FileTree
  alias Minga.Language.Devicon

  # Box-drawing characters matching the semantic file-tree builder
  @guide_pipe "│ "
  @guide_tee "├─"
  @guide_elbow "└─"
  @guide_blank "  "

  # Nerd Font folder icons matching the semantic file-tree builder
  @folder_closed "\u{F0256}"
  @folder_open "\u{F0DCF}"

  @doc """
  Starts a `*File Tree*` buffer and syncs tree entries into it.

  Returns the buffer pid.
  """
  @spec start_buffer(FileTree.t()) :: pid() | nil
  @spec start_buffer(FileTree.t(), Minga.Config.Options.server()) :: pid() | nil
  def start_buffer(tree, options_server \\ Minga.Config.Options.default_server()) do
    pid =
      case Buffer.start_link(
             content: "",
             buffer_type: :nofile,
             buffer_name: "*File Tree*",
             read_only: true,
             unlisted: true,
             options_server: options_server
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
  def sync(pid, %FileTree{} = tree) do
    text =
      case tree.entries do
        entries when is_list(entries) ->
          entries_to_text(entries, tree.expanded)

        nil ->
          ""
      end

    Buffer.replace_generated_content(pid, text)
    Buffer.move_to(pid, {if(text == "", do: 0, else: tree.cursor), 0})
    :ok
  end

  @doc """
  Converts tree entries to a single text string with newlines.
  Each entry becomes one line: guides + icon + name.
  """
  @spec entries_to_text([FileTree.entry()], MapSet.t(String.t())) :: String.t()
  def entries_to_text(entries, expanded) do
    # One registry snapshot for every file line instead of one lookup per line.
    filetypes = entries |> Enum.map(&filetype_subject/1) |> Language.detect_filetypes()

    entries
    |> Enum.zip_with(filetypes, &entry_to_line(&1, &2, expanded))
    |> Enum.join("\n")
  end

  @spec filetype_subject(FileTree.entry()) :: String.t() | nil
  defp filetype_subject(%{dir?: true}), do: nil
  defp filetype_subject(%{path: path}), do: path

  @spec entry_to_line(FileTree.entry(), atom(), MapSet.t(String.t())) :: String.t()
  defp entry_to_line(entry, filetype, expanded) do
    guides = build_guides(entry.guides, entry.last_child?)
    is_expanded = entry.dir? and MapSet.member?(expanded, entry.path)

    icon =
      case {entry.dir?, is_expanded} do
        {true, true} -> @folder_open
        {true, false} -> @folder_closed
        {false, _} -> Devicon.icon(filetype)
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

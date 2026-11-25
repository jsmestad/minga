defmodule MingaEditor.FileTree.EmptyFolder do
  @moduledoc """
  What the file tree says when its folder has nothing in it, and the next steps it offers: a new file (`a`) or a new folder (`A`), the tree's own keys, as in dired.

  The builder draws it (`MingaEditor.RenderModel.UI.FileTreeBuilder`), and the file tree's keys run the preselected step (`MingaEditor.Input.FileTreeHandler`), so both read the same steps.
  """

  alias Minga.RenderModel.UI.EmptyList
  alias MingaEditor.RenderModel.UI.EmptyStateBuilder

  @steps [{:tree_new_file, "New file", "a"}, {:tree_new_folder, "New folder", "A"}]

  @doc "The empty-state anatomy for the folder at `root`, with `selected` preselected."
  @spec empty_list(String.t() | nil, non_neg_integer()) :: EmptyList.t()
  def empty_list(root, selected) do
    EmptyStateBuilder.empty_list(
      "#{folder_name(root)} is empty.",
      "Make the first file or folder here.",
      @steps,
      selected: selected
    )
  end

  @doc "How many next steps an empty folder offers."
  @spec step_count() :: pos_integer()
  def step_count, do: length(@steps)

  @doc "The command of the step at `index`."
  @spec command_at(non_neg_integer()) :: atom()
  def command_at(index) when is_integer(index) do
    {command, _label, _key} = Enum.at(@steps, index, hd(@steps))
    command
  end

  @spec folder_name(String.t() | nil) :: String.t()
  defp folder_name(nil), do: "This folder"
  defp folder_name(root), do: Path.basename(root) <> "/"
end

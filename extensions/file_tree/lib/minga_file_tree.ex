defmodule MingaFileTree do
  @moduledoc """
  Bundled FileTree UI extension for Minga.

  The project file-tree domain model stays in core. This extension owns the UI state, commands, input handler, sidebar contribution, and TUI/native semantic snapshots.
  """

  use Minga.Extension

  command :toggle_file_tree, "Toggle file tree", requires_buffer: false, execute: {MingaFileTree.Commands, :toggle}
  command :tree_open_or_toggle, "Open file or toggle directory", requires_buffer: false, execute: {MingaFileTree.Commands, :open_or_toggle}
  command :tree_toggle_directory, "Toggle directory in tree", requires_buffer: false, execute: {MingaFileTree.Commands, :toggle_directory}
  command :tree_expand, "Expand tree node", requires_buffer: false, execute: {MingaFileTree.Commands, :expand}
  command :tree_collapse, "Collapse tree node", requires_buffer: false, execute: {MingaFileTree.Commands, :collapse}
  command :tree_toggle_hidden, "Toggle hidden files in tree", requires_buffer: false, execute: {MingaFileTree.Commands, :toggle_hidden}
  command :tree_refresh, "Refresh file tree", requires_buffer: false, execute: {MingaFileTree.Commands, :refresh}
  command :tree_copy_path, "Copy file tree path", requires_buffer: false, execute: {MingaFileTree.Commands, :copy_path}
  command :tree_mark_copy, "Mark file tree entry for copy", requires_buffer: false, execute: {MingaFileTree.Commands, :mark_copy}
  command :tree_mark_move, "Mark file tree entry for move", requires_buffer: false, execute: {MingaFileTree.Commands, :mark_move}
  command :tree_paste, "Paste marked file tree entry", requires_buffer: false, execute: {MingaFileTree.Commands, :paste}
  command :tree_root_parent, "Root file tree at parent directory", requires_buffer: false, execute: {MingaFileTree.Commands, :root_parent}
  command :tree_root_selected, "Root file tree at selected directory", requires_buffer: false, execute: {MingaFileTree.Commands, :root_selected}
  command :tree_root_original, "Restore file tree project root", requires_buffer: false, execute: {MingaFileTree.Commands, :root_original}
  command :tree_filter, "Filter file tree", requires_buffer: false, execute: {MingaFileTree.Commands, :filter}
  command :tree_toggle_help, "Toggle file tree help", requires_buffer: false, execute: {MingaFileTree.Commands, :toggle_help}
  command :tree_close, "Close file tree", requires_buffer: false, execute: {MingaFileTree.Commands, :close}
  command :tree_collapse_all, "Collapse all directories in tree", requires_buffer: false, execute: {MingaFileTree.Commands, :collapse_all}
  command :tree_new_file, "Create new file in tree", requires_buffer: false, execute: {MingaFileTree.Commands, :new_file}
  command :tree_new_folder, "Create new folder in tree", requires_buffer: false, execute: {MingaFileTree.Commands, :new_folder}
  command :tree_rename, "Rename file or folder in tree", requires_buffer: false, execute: {MingaFileTree.Commands, :rename}
  command :tree_confirm_editing, "Confirm file tree inline edit", requires_buffer: false, execute: {MingaFileTree.Commands, :confirm_editing}
  command :tree_cancel_editing, "Cancel file tree inline edit", requires_buffer: false, execute: {MingaFileTree.Commands, :cancel_editing}
  command :tree_reveal_active, "Reveal active file in tree", requires_buffer: false, execute: {MingaFileTree.Commands, :reveal_active_file}
  command :tree_delete, "Delete file or folder in tree", requires_buffer: false, execute: {MingaFileTree.Commands, :delete}
  command :tree_duplicate, "Duplicate file or folder in tree", requires_buffer: false, execute: {MingaFileTree.Commands, :duplicate}

  keybind :normal, "SPC o p", :toggle_file_tree, "Toggle file tree"

  @impl true
  def name, do: :minga_file_tree

  @impl true
  def description, do: "Project FileTree sidebar"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config) do
    MingaFileTree.Feature.register_contributions()
    {:ok, %{}}
  end
end

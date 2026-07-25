defmodule MingaEditor.RenderModel.UI.FileTreeBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.Diagnostics, as: DiagnosticStore
  alias Minga.Language
  alias Minga.LSP.SyncServer
  alias Minga.Project.FileTree
  alias Minga.RenderModel.UI.FileTree, as: FileTreeModel
  alias Minga.RenderModel.UI.FileTree.Editing, as: FileTreeEditingModel
  alias Minga.RenderModel.UI.FileTree.Flags, as: FileTreeFlagsModel
  alias Minga.RenderModel.UI.FileTree.Row, as: FileTreeRowModel
  alias MingaEditor.FileTree.Diagnostics, as: FileTreeDiagnostics
  alias MingaEditor.FileTree.Row
  alias MingaEditor.FileTree.Rows
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias Minga.Language.Devicon
  alias MingaEditor.UI.Theme

  # Named folders resolved via Devicon.folder_icon_and_color/1

  @spec build(Context.t()) :: FileTreeModel.t()
  def build(%Context{workspace: %{file_tree: %FileTreeState{} = file_tree}} = ctx) do
    status = FileTreeState.status(file_tree)

    case {status, FileTreeState.tree(file_tree)} do
      {status, %FileTree{} = tree} when status in [:ready, :hidden] ->
        build_full(FileTree.ensure_entries(tree), file_tree, ctx, status)

      {:hidden, nil} ->
        build_hidden(file_tree.project_root)

      {status, _tree} ->
        build_state(file_tree, status)
    end
  end

  def build(%Context{workspace: %{file_tree: %{project_root: root_path}}}) do
    build_hidden(root_path)
  end

  def build(%Context{}) do
    build_hidden(nil)
  end

  @spec build_full(FileTree.t(), FileTreeState.t(), Context.t(), FileTreeModel.status()) ::
          FileTreeModel.t()
  defp build_full(tree, file_tree, ctx, status) do
    active_path = active_buffer_path(ctx)
    dirty_path_set = dirty_paths(ctx.workspace.buffers)
    diagnostics = file_tree_diagnostics(tree.root)

    rows =
      tree
      |> Rows.from_tree(
        active_path: active_path,
        dirty_paths: dirty_path_set,
        editing: FileTreeState.editing(file_tree),
        focused: FileTreeState.focused?(file_tree),
        git_status: tree.git_status,
        diagnostics: diagnostics,
        heat_levels: file_tree_heat_levels(),
        selected_index: tree.cursor
      )
      |> Enum.map(&row_model(&1, ctx.intent.frame.theme))

    %FileTreeModel{
      root_path: tree.root,
      tree_width: tree.width,
      status: status,
      focused?: FileTreeState.focused?(file_tree),
      local_navigation?: local_navigation?(file_tree),
      selected_id: selected_row_id(tree),
      rows: rows
    }
  end

  @spec build_state(FileTreeState.t(), FileTreeState.status()) :: FileTreeModel.t()
  defp build_state(%FileTreeState{} = file_tree, status) do
    %FileTreeModel{
      root_path: file_tree.project_root,
      tree_width: FileTreeState.width(file_tree),
      status: status,
      focused?: false,
      selected_id: "",
      rows: []
    }
  end

  @spec build_hidden(String.t() | nil) :: FileTreeModel.t()
  defp build_hidden(root_path) do
    %FileTreeModel{root_path: root_path, status: :hidden}
  end

  @spec row_model(Row.t(), Theme.t()) :: FileTreeRowModel.t()
  defp row_model(%Row{} = row, %Theme{} = theme) do
    %FileTreeRowModel{
      id: row.id,
      path: row.path,
      name: row.name,
      icon: row_icon(row),
      icon_color: row_icon_color(row, theme),
      flags: %FileTreeFlagsModel{
        directory?: row.directory?,
        expanded?: row.expanded?,
        active?: row.active?,
        dirty?: row.dirty?,
        last_child?: row.last_child?
      },
      git_status: row.git_status,
      diagnostics: FileTreeDiagnostics.to_tuple(row.diagnostics),
      heat_level: row.heat_level,
      depth: row.depth,
      guides: row.guides,
      editing: editing_model(row.editing)
    }
  end

  @spec editing_model(FileTreeState.editing() | nil) :: FileTreeEditingModel.t() | nil
  defp editing_model(nil), do: nil
  defp editing_model(%{type: type, text: text}), do: %FileTreeEditingModel{type: type, text: text}

  @spec row_icon(Row.t()) :: String.t()
  defp row_icon(%Row{directory?: true, name: name}),
    do: elem(Devicon.folder_icon_and_color(name), 0)

  defp row_icon(%Row{name: name}), do: Devicon.icon(Language.detect_filetype(name))

  @spec row_icon_color(Row.t(), Theme.t()) :: non_neg_integer()
  defp row_icon_color(%Row{directory?: true, name: name}, _theme),
    do: elem(Devicon.folder_icon_and_color(name), 1)

  defp row_icon_color(%Row{name: name}, theme),
    do: Theme.icon_color(theme, Language.detect_filetype(name))

  @spec active_buffer_path(Context.t()) :: String.t() | nil
  defp active_buffer_path(%Context{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    Buffer.file_path(buf)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp active_buffer_path(_ctx), do: nil

  @spec file_tree_diagnostics(String.t()) :: %{String.t() => FileTreeDiagnostics.t()}
  defp file_tree_diagnostics(root) when is_binary(root) do
    root
    |> SyncServer.path_to_uri()
    |> DiagnosticStore.count_tuples_by_uri_prefix()
    |> Map.new(fn {uri, counts} ->
      {SyncServer.uri_to_path(uri), FileTreeDiagnostics.new(counts)}
    end)
  rescue
    ArgumentError -> %{}
  catch
    :exit, _ -> %{}
  end

  # Extension-contributed familiarity/heat levels by absolute file path. A
  # single bulk read; directory roll-up happens in `Rows.from_tree`.
  @spec file_tree_heat_levels() :: %{String.t() => 0..4}
  defp file_tree_heat_levels do
    Minga.Extension.Badge.file_levels_map()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @spec selected_row_id(FileTree.t()) :: String.t()
  defp selected_row_id(%FileTree{entries: entries, cursor: cursor}) when is_list(entries) do
    case Enum.at(entries, cursor) do
      nil -> ""
      entry -> Row.id_for(entry)
    end
  end

  @spec local_navigation?(FileTreeState.t()) :: boolean()
  defp local_navigation?(%FileTreeState{} = file_tree) do
    FileTreeState.focused?(file_tree) and file_tree.interaction == :browse
  end

  @spec dirty_paths(MingaEditor.State.Buffers.t()) :: MapSet.t(String.t())
  defp dirty_paths(%{list: buffer_list}) do
    buffer_list
    |> Enum.flat_map(&dirty_buffer_path/1)
    |> Enum.map(&Path.expand/1)
    |> MapSet.new()
  end

  @spec dirty_buffer_path(pid()) :: [String.t()]
  defp dirty_buffer_path(pid) when is_pid(pid) do
    if Buffer.dirty?(pid), do: present_path(Buffer.file_path(pid)), else: []
  catch
    :exit, _ -> []
  end

  @spec present_path(String.t() | nil) :: [String.t()]
  defp present_path(nil), do: []
  defp present_path(path), do: [path]
end

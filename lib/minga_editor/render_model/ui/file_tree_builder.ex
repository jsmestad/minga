defmodule MingaEditor.RenderModel.UI.FileTreeBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.Diagnostics, as: DiagnosticStore
  alias Minga.LSP.SyncServer
  alias Minga.Project.FileTree
  alias Minga.RenderModel.UI.FileTree, as: FileTreeModel
  alias MingaEditor.FileTree.Diagnostics, as: FileTreeDiagnostics
  alias MingaEditor.FileTree.Rows
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.State.FileTree, as: FileTreeState

  @spec build(Context.t()) :: FileTreeModel.t()
  def build(%Context{file_tree: %{tree: %FileTree{} = tree} = file_tree} = ctx) do
    tree = FileTree.ensure_entries(tree)
    tree_status = FileTreeState.status(file_tree)

    case tree_status do
      :ready ->
        build_ready(tree, file_tree, ctx)

      status ->
        build_state(file_tree, status)
    end
  end

  def build(%Context{file_tree: %FileTreeState{} = file_tree}) do
    case FileTreeState.status(file_tree) do
      :hidden -> build_hidden(file_tree.project_root)
      status -> build_state(file_tree, status)
    end
  end

  def build(%Context{file_tree: %{project_root: root_path}}) do
    build_hidden(root_path)
  end

  def build(%Context{}) do
    build_hidden(nil)
  end

  @spec build_ready(FileTree.t(), FileTreeState.t(), Context.t()) :: FileTreeModel.t()
  defp build_ready(tree, file_tree, ctx) do
    active_path = active_buffer_path(ctx)
    dirty_path_set = dirty_paths(ctx.buffers)
    diagnostics = file_tree_diagnostics(tree.root)

    structural_fp =
      file_tree_ready_structural_fingerprint(
        tree,
        file_tree,
        active_path,
        dirty_path_set,
        diagnostics
      )

    selection_fp = file_tree_selection_fingerprint(tree, file_tree)

    rows =
      Rows.from_tree(tree,
        active_path: active_path,
        dirty_paths: dirty_path_set,
        editing: Map.get(file_tree, :editing),
        focused: file_tree_focused?(file_tree),
        git_status: tree.git_status,
        diagnostics: diagnostics,
        selected_index: tree.cursor
      )

    encoded =
      ProtocolGUI.encode_gui_file_tree(
        tree.root,
        tree.width,
        :ready,
        file_tree_focused?(file_tree),
        rows
      )

    selection_encoded =
      ProtocolGUI.encode_gui_file_tree_selection(
        selected_row_id(tree),
        file_tree_focused?(file_tree)
      )

    %FileTreeModel{
      encoded: encoded,
      selection_encoded: selection_encoded,
      fingerprint: {:ready, structural_fp, selection_fp}
    }
  end

  @spec build_state(FileTreeState.t(), FileTreeState.tree_status()) :: FileTreeModel.t()
  defp build_state(%FileTreeState{} = file_tree, status) do
    width = FileTreeState.width(file_tree)
    encoded = ProtocolGUI.encode_gui_file_tree(file_tree.project_root, width, status, false, [])

    %FileTreeModel{
      encoded: encoded,
      fingerprint: {:file_tree_state, file_tree.project_root || "", width, status}
    }
  end

  @spec build_hidden(String.t() | nil) :: FileTreeModel.t()
  defp build_hidden(root_path) do
    encoded = ProtocolGUI.encode_hidden_gui_file_tree(root_path)

    %FileTreeModel{
      encoded: encoded,
      fingerprint: {:no_tree, root_path || ""}
    }
  end

  # ── Helpers (moved from GUI.ex) ──

  @spec active_buffer_path(Context.t()) :: String.t() | nil
  defp active_buffer_path(%{buffers: %{active: buf}}) when is_pid(buf) do
    Buffer.file_path(buf)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp active_buffer_path(_ctx), do: nil

  @spec file_tree_ready_structural_fingerprint(
          FileTree.t(),
          FileTreeState.t(),
          String.t() | nil,
          MapSet.t(String.t()),
          %{String.t() => FileTreeDiagnostics.t()}
        ) :: non_neg_integer()
  defp file_tree_ready_structural_fingerprint(
         tree,
         file_tree,
         active_path,
         dirty_path_set,
         diagnostics
       ) do
    :erlang.phash2({
      tree.root,
      tree.width,
      tree.show_hidden,
      tree.expanded,
      tree.entries,
      tree.git_status,
      Map.get(file_tree, :editing),
      active_path,
      dirty_path_set,
      diagnostics
    })
  end

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

  @spec file_tree_selection_fingerprint(FileTree.t(), map()) :: non_neg_integer()
  defp file_tree_selection_fingerprint(tree, file_tree) do
    :erlang.phash2({selected_row_id(tree), file_tree_focused?(file_tree)})
  end

  @spec selected_row_id(FileTree.t()) :: String.t()
  defp selected_row_id(%FileTree{entries: entries, cursor: cursor}) when is_list(entries) do
    case Enum.at(entries, cursor) do
      nil -> ""
      entry -> MingaEditor.FileTree.Row.id_for(entry)
    end
  end

  @spec file_tree_focused?(map()) :: boolean()
  defp file_tree_focused?(file_tree), do: Map.get(file_tree, :focused, false)

  @spec dirty_paths(MingaEditor.State.Buffers.t()) :: MapSet.t(String.t())
  defp dirty_paths(%{list: buffer_list}) do
    buffer_list
    |> Enum.flat_map(&dirty_buffer_path/1)
    |> Enum.map(&Path.expand/1)
    |> MapSet.new()
  end

  defp dirty_paths(_), do: MapSet.new()

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

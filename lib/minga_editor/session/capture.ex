defmodule MingaEditor.Session.Capture do
  @moduledoc """
  Builds a `Minga.Session.Snapshot` from editor state: what the window holds right now.

  The snapshot names the project root, every open file with its cursor, the window splits with each window's file, cursor and scroll, which window has focus, and the active file. Buffers without a file (scratch, `*Messages*`) and windows that show no file (a conversation, the home view) are left out, so a restore reopens only what it can.
  """

  alias Minga.Buffer
  alias Minga.Session.BufferEntry
  alias Minga.Session.Layout
  alias Minga.Session.Pane
  alias Minga.Session.Snapshot
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  @doc "Captures the editor's restorable window state."
  @spec snapshot(EditorState.t()) :: Snapshot.t()
  def snapshot(%EditorState{workspace: workspace} = state) do
    inventory = BufferRegistry.buffer_inventory(state)
    paths = buffer_paths(inventory)
    windows = workspace.windows
    layout = layout(windows, paths)

    %Snapshot{
      version: Snapshot.current_version(),
      project_root: MingaEditor.Session.State.project_root(workspace),
      buffers: inventory |> Enum.map(&entry(&1, paths)) |> Enum.reject(&is_nil/1),
      active_file: Map.get(paths, workspace.buffers.active),
      layout: layout,
      active_pane: active_pane(windows, paths),
      clean_shutdown: false
    }
  end

  @spec buffer_paths([pid()]) :: %{pid() => String.t()}
  defp buffer_paths(pids) do
    for pid <- pids, path = Buffer.file_path(pid), is_binary(path), into: %{}, do: {pid, path}
  end

  @spec entry(pid(), %{pid() => String.t()}) :: BufferEntry.t() | nil
  defp entry(pid, paths) do
    case Map.fetch(paths, pid) do
      {:ok, path} ->
        {line, col} = cursor(pid)
        %BufferEntry{file: path, cursor_line: line, cursor_col: col}

      :error ->
        nil
    end
  end

  @spec layout(MingaEditor.State.Windows.t(), %{pid() => String.t()}) :: Layout.t() | nil
  defp layout(%{tree: nil}, _paths), do: nil

  defp layout(%{tree: tree, map: map, active: active}, paths) do
    Layout.build(tree, fn id -> pane(Map.get(map, id), paths, id == active) end)
  end

  # The focused window's cursor lives in its buffer; other windows keep their own.
  @spec pane(Window.t() | nil, %{pid() => String.t()}, boolean()) :: Pane.t() | nil
  defp pane(window, paths, active? \\ false)

  defp pane(%Window{content: {:buffer, pid}} = window, paths, active?) do
    case Map.fetch(paths, pid) do
      {:ok, path} ->
        {line, col} = if active?, do: cursor(pid), else: window.cursor

        %Pane{file: path, cursor_line: line, cursor_col: col, top: window.viewport.top}

      :error ->
        nil
    end
  end

  defp pane(_window, _paths, _active?), do: nil

  # The focused window's position among the saved panes, in leaf order.
  @spec active_pane(MingaEditor.State.Windows.t(), %{pid() => String.t()}) :: non_neg_integer()
  defp active_pane(%{tree: nil}, _paths), do: 0

  defp active_pane(%{tree: tree, map: map, active: active}, paths) do
    tree
    |> MingaEditor.WindowTree.leaves()
    |> Enum.filter(&pane(Map.get(map, &1), paths))
    |> Enum.find_index(&(&1 == active))
    |> Kernel.||(0)
  end

  @spec cursor(pid()) :: {non_neg_integer(), non_neg_integer()}
  defp cursor(pid) do
    Buffer.cursor(pid)
  catch
    # Race window: the buffer may exit between listing and this call.
    :exit, _ -> {0, 0}
  end
end

defmodule Minga.Picker.RecentFileSource do
  @moduledoc """
  Picker source for recently opened files in the current project.

  Lists files from `Minga.Project.recent_files/0`, most recently opened first.
  Selecting a file opens it (or switches to it if already in a buffer).
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Project

  @impl true
  @spec title() :: String.t()
  def title, do: "Recent files"

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(_context) do
    root = Project.root()
    files = Project.recent_files()

    files
    |> Enum.with_index()
    |> Enum.map(fn {rel_path, idx} ->
      label = Path.basename(rel_path)
      desc = if root, do: rel_path, else: rel_path
      {idx, label, desc}
    end)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({_idx, _label, rel_path}, state) do
    root = project_root()
    abs_path = Path.join(root, rel_path)

    case find_buffer_by_path(state, abs_path) do
      nil ->
        case start_buffer(abs_path) do
          {:ok, pid} ->
            EditorState.add_buffer(state, pid)

          {:error, reason} ->
            Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        EditorState.switch_buffer(state, idx)
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(%{picker_ui: %{restore: restore_idx}} = state) when is_integer(restore_idx) do
    EditorState.switch_buffer(state, restore_idx)
  end

  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec project_root() :: String.t()
  defp project_root do
    case Project.root() do
      nil -> File.cwd!()
      root -> root
    end
  catch
    :exit, _ -> File.cwd!()
  end

  @spec find_buffer_by_path(map(), String.t()) :: non_neg_integer() | nil
  defp find_buffer_by_path(%{buffers: %{list: buffers}}, file_path) do
    Enum.find_index(buffers, fn buf ->
      Process.alive?(buf) && BufferServer.file_path(buf) == file_path
    end)
  end

  @spec start_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  defp start_buffer(file_path) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {BufferServer, file_path: file_path}
    )
  end
end

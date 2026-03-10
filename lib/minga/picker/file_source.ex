defmodule Minga.Picker.FileSource do
  @moduledoc """
  Picker source for finding and opening files in the project.

  Lists all files in the project directory using `Minga.FileFind` and opens
  the selected file in a new buffer (or switches to it if already open).
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState

  require Logger

  @impl true
  @spec title() :: String.t()
  def title, do: "Find file"

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(_context) do
    root = project_root()

    case Minga.FileFind.list_files(root) do
      {:ok, paths} ->
        Enum.map(paths, fn path ->
          {path, Path.basename(path), path}
        end)

      {:error, msg} ->
        Logger.error("find_file: #{msg}")
        []
    end
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({rel_path, _label, _desc}, state) do
    abs_path = Path.expand(rel_path)

    case find_buffer_by_path(state, abs_path) do
      nil ->
        case start_buffer(abs_path) do
          {:ok, pid} ->
            EditorState.add_buffer(state, pid)

          {:error, reason} ->
            Logger.error("Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        # If the buffer already has a tab, switch to that tab instead
        # of just changing the buffer index. This correctly leaves
        # agentic view when opening a file from an agent tab.
        pid = Enum.at(state.buffers.list, idx)
        tab = EditorState.find_tab_by_buffer(state, pid)

        if tab do
          EditorState.switch_tab(state, tab.id)
        else
          EditorState.switch_buffer(state, idx)
        end
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(%{picker_ui: %{restore: restore_idx}} = state) when is_integer(restore_idx) do
    EditorState.switch_buffer(state, restore_idx)
  end

  def on_cancel(state), do: state

  @impl true
  @spec actions(Minga.Picker.item()) :: [Minga.Picker.Source.action_entry()]
  def actions(_item) do
    [{"Open", :open}, {"Delete", :delete}]
  end

  @impl true
  @spec on_action(atom(), Minga.Picker.item(), term()) :: term()
  def on_action(:open, item, state), do: on_select(item, state)

  def on_action(:delete, {rel_path, _label, _desc}, state) do
    abs_path = Path.expand(rel_path)

    case File.rm(abs_path) do
      :ok ->
        Logger.info("Deleted file: #{abs_path}")
        state

      {:error, reason} ->
        Logger.error("Failed to delete file: #{inspect(reason)}")
        state
    end
  end

  def on_action(_action, _item, state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec project_root() :: String.t()
  defp project_root do
    case Minga.Project.root() do
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

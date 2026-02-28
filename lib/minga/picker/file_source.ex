defmodule Minga.Picker.FileSource do
  @moduledoc """
  Picker source for finding and opening files in the project.

  Lists all files in the project directory using `Minga.FileFind` and opens
  the selected file in a new buffer (or switches to it if already open).
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer

  require Logger

  @impl true
  @spec title() :: String.t()
  def title, do: "Find file"

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(_context) do
    root = File.cwd!()

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
            add_buffer(state, pid)

          {:error, reason} ->
            Logger.error("Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        switch_to_buffer(state, idx)
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(%{picker_restore: restore_idx} = state) when is_integer(restore_idx) do
    switch_to_buffer(state, restore_idx)
  end

  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec find_buffer_by_path(map(), String.t()) :: non_neg_integer() | nil
  defp find_buffer_by_path(%{buffers: buffers}, file_path) do
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

  @spec add_buffer(map(), pid()) :: map()
  defp add_buffer(state, pid) do
    buffers = state.buffers ++ [pid]
    idx = length(buffers) - 1
    %{state | buffers: buffers, active_buffer: idx, buffer: pid}
  end

  @spec switch_to_buffer(map(), non_neg_integer()) :: map()
  defp switch_to_buffer(%{buffers: buffers} = state, idx) when length(buffers) > 0 do
    idx = rem(idx, length(buffers))
    idx = if idx < 0, do: idx + length(buffers), else: idx
    pid = Enum.at(buffers, idx)
    %{state | active_buffer: idx, buffer: pid}
  end

  defp switch_to_buffer(state, _idx), do: state
end

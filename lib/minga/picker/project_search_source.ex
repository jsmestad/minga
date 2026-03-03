defmodule Minga.Picker.ProjectSearchSource do
  @moduledoc """
  Picker source for project-wide search results.

  Displays results from `Minga.ProjectSearch` in a filterable picker.
  Selecting a result opens the file at the matching line and column.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState

  require Logger

  @impl true
  @spec title() :: String.t()
  def title, do: "Search project"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(%{search: %{project_results: results}}) when is_list(results) do
    results
    |> Enum.with_index()
    |> Enum.map(fn {match, idx} ->
      label = "#{match.file}:#{match.line}"
      desc = String.trim(match.text)
      {idx, label, desc}
    end)
  end

  def candidates(_context), do: []

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({idx, _label, _desc}, %{search: %{project_results: results}} = state)
      when is_integer(idx) do
    case Enum.at(results, idx) do
      nil -> state
      match -> open_match(state, match)
    end
  end

  def on_select(_item, state), do: state

  @spec open_match(map(), map()) :: map()
  defp open_match(state, match) do
    abs_path = Path.expand(match.file)
    line = max(match.line - 1, 0)
    col = match.col

    case find_buffer_by_path(state, abs_path) do
      nil -> open_new_buffer(state, abs_path, line, col)
      buf_idx -> jump_to_buffer(state, buf_idx, line, col)
    end
  end

  @spec open_new_buffer(map(), String.t(), non_neg_integer(), non_neg_integer()) :: map()
  defp open_new_buffer(state, abs_path, line, col) do
    case start_buffer(abs_path) do
      {:ok, pid} ->
        new_state = EditorState.add_buffer(state, pid)
        BufferServer.move_to(pid, {line, col})
        new_state

      {:error, reason} ->
        Logger.error("Failed to open file: #{inspect(reason)}")
        state
    end
  end

  @spec jump_to_buffer(map(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: map()
  defp jump_to_buffer(state, buf_idx, line, col) do
    new_state = EditorState.switch_buffer(state, buf_idx)
    pid = Enum.at(state.buf.buffers, buf_idx)
    BufferServer.move_to(pid, {line, col})
    new_state
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(%{picker_ui: %{restore: restore_idx}} = state) when is_integer(restore_idx) do
    EditorState.switch_buffer(state, restore_idx)
  end

  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec find_buffer_by_path(map(), String.t()) :: non_neg_integer() | nil
  defp find_buffer_by_path(%{buf: %{buffers: buffers}}, file_path) do
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

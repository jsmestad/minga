defmodule Minga.Picker.ProjectSearchSource do
  @moduledoc """
  Picker source for project-wide search results.

  Displays results from `Minga.ProjectSearch` in a filterable picker.
  Selecting a result opens the file at the matching line and column.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Picker.Item

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Devicon
  alias Minga.Editor.State, as: EditorState
  alias Minga.Filetype
  alias Minga.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Search project"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(%EditorState{workspace: %{search: %{project_results: results}}}) when is_list(results) do
    results
    |> Enum.with_index()
    |> Enum.map(fn {match, idx} ->
      filename = Path.basename(match.file)
      ft = Filetype.detect(filename)
      {icon, color} = Devicon.icon_and_color(ft)
      label = "#{icon} #{match.file}:#{match.line}"
      desc = String.trim(match.text)
      %Item{id: idx, label: label, description: desc, icon_color: color}
    end)
  end

  def candidates(_context), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: idx}, %EditorState{workspace: %{search: %{project_results: results}}} = state)
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

    case EditorState.find_buffer_by_path(state, abs_path) do
      nil -> open_new_buffer(state, abs_path, line, col)
      buf_idx -> jump_to_buffer(state, buf_idx, line, col)
    end
  end

  @spec open_new_buffer(map(), String.t(), non_neg_integer(), non_neg_integer()) :: map()
  defp open_new_buffer(state, abs_path, line, col) do
    case EditorState.start_buffer(abs_path) do
      {:ok, pid} ->
        new_state = EditorState.add_buffer(state, pid)
        BufferServer.move_to(pid, {line, col})
        new_state

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
        state
    end
  end

  @spec jump_to_buffer(map(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: map()
  defp jump_to_buffer(state, buf_idx, line, col) do
    new_state = EditorState.switch_buffer(state, buf_idx)
    pid = Enum.at(state.workspace.buffers.list, buf_idx)
    BufferServer.move_to(pid, {line, col})
    new_state
  end

  @impl true
  def on_cancel(state), do: Source.restore_or_keep(state)

  # ── Private ─────────────────────────────────────────────────────────────────
end

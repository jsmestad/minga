defmodule MingaEditor.UI.Picker.ProjectSearchSource do
  @moduledoc """
  Picker source for project-wide search results.

  The scan runs off the editor input path: this source is async, so
  `PickerUI.open/3` shows the picker immediately with a "Searching…" indicator
  and `async_fetch/1` runs `Minga.Project.ProjectSearch.search/2` in a background
  task. The query is read from the stashed `search.project_query`. Each match is
  embedded directly in its `Item.id`, so selecting a result resolves the file and
  position without a separate cached-results lookup. When the in-process result
  cap is hit, the fetch reports a truncated status.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias Minga.Language
  alias Minga.Language.Devicon
  alias Minga.Project.ProjectSearch
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @truncated_status "Results truncated to #{ProjectSearch.max_results()}"

  @impl true
  @spec title() :: String.t()
  def title, do: "Search project"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(ctx) do
    case async_fetch(ctx) do
      {:ok, items, _meta} -> items
      {:error, _reason} -> []
    end
  end

  @impl true
  @spec async_fetch(Context.t()) ::
          {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{search: %{project_query: query}})
      when is_binary(query) and query != "" do
    case ProjectSearch.search(query, Minga.Project.resolve_root()) do
      {:ok, matches, truncated?} ->
        {:ok, build_items(matches), fetch_meta(truncated?)}

      {:error, message} ->
        {:error, message}
    end
  end

  def async_fetch(_ctx), do: {:ok, [], %{}}

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: %{file: _file} = match}, state) do
    open_match(state, match)
  end

  def on_select(_item, state), do: state

  @impl true
  def on_cancel(state), do: Source.restore_or_keep(state)

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec build_items([ProjectSearch.match()]) :: [Item.t()]
  defp build_items(matches) do
    Enum.map(matches, fn match ->
      filename = Path.basename(match.file)
      ft = Language.detect_filetype(filename)
      {icon, color} = Devicon.icon_and_color(ft)
      label = "#{icon} #{match.file}:#{match.line}"
      desc = String.trim(match.text)
      %Item{id: match, label: label, description: desc, icon_color: color}
    end)
  end

  @spec fetch_meta(boolean()) :: Source.fetch_meta()
  defp fetch_meta(true), do: %{status: @truncated_status}
  defp fetch_meta(false), do: %{}

  @spec open_match(map(), ProjectSearch.match()) :: map()
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
    case EditorState.start_buffer(abs_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        new_state = EditorState.add_buffer(state, pid)
        Buffer.move_to(pid, {line, col})
        new_state

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
        state
    end
  end

  @spec jump_to_buffer(map(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: map()
  defp jump_to_buffer(state, buf_idx, line, col) do
    new_state = MingaEditor.BufferActivation.activate(state, buf_idx)
    pid = Enum.at(state.workspace.buffers.list, buf_idx)
    Buffer.move_to(pid, {line, col})
    new_state
  end
end

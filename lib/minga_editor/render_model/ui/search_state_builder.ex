defmodule MingaEditor.RenderModel.UI.SearchStateBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.Editing.Search
  alias Minga.RenderModel.UI.SearchState, as: SearchStateModel
  alias MingaEditor.State.Search, as: EditorSearch

  @spec build(EditorSearch.t(), pid() | nil) :: SearchStateModel.t()
  def build(%EditorSearch{gui_search: nil}, _active_buffer) do
    %SearchStateModel{
      active: false,
      case_sensitive: false,
      whole_word: false,
      regex: false,
      replace_mode: false
    }
  end

  def build(%EditorSearch{gui_search: %{active: false} = gui_search}, _active_buffer),
    do: build_model(gui_search, 0, 0)

  def build(%EditorSearch{gui_search: %{active: true} = gui_search}, active_buffer) do
    search_opts = [
      case_sensitive: gui_search.case_sensitive,
      whole_word: gui_search.whole_word,
      regex: gui_search.regex
    ]

    {match_count, current_index} =
      compute_search_stats(active_buffer, gui_search.query, search_opts)

    build_model(gui_search, match_count, current_index)
  end

  @spec build_model(EditorSearch.gui_search(), non_neg_integer(), non_neg_integer()) ::
          SearchStateModel.t()
  defp build_model(gui_search, match_count, current_index) do
    %SearchStateModel{
      active: gui_search.active,
      query: gui_search.query,
      session_id: gui_search.session_id,
      acknowledged_edit_seq: gui_search.acknowledged_edit_seq,
      match_count: match_count,
      current_index: current_index,
      case_sensitive: gui_search.case_sensitive,
      whole_word: gui_search.whole_word,
      regex: gui_search.regex,
      replace_mode: gui_search.replace_mode
    }
  end

  @spec compute_search_stats(pid() | nil, String.t() | nil, Search.search_opts()) ::
          {non_neg_integer(), non_neg_integer()}
  defp compute_search_stats(_buf, nil, _opts), do: {0, 0}
  defp compute_search_stats(_buf, "", _opts), do: {0, 0}
  defp compute_search_stats(nil, _pattern, _opts), do: {0, 0}

  defp compute_search_stats(buf, pattern, opts) when is_pid(buf) do
    content = Buffer.content(buf)
    lines = :binary.split(content, "\n", [:global])
    all_matches = Search.find_all_in_range(lines, pattern, 0, opts)
    match_count = Enum.count(all_matches)

    if match_count > 0 do
      cursor = Buffer.cursor(buf)
      current_index = find_current_match_index(all_matches, cursor)
      {match_count, current_index}
    else
      {0, 0}
    end
  rescue
    _ -> {0, 0}
  catch
    :exit, _ -> {0, 0}
  end

  @spec find_current_match_index(
          [Search.Match.t()],
          {non_neg_integer(), non_neg_integer()}
        ) :: non_neg_integer()
  defp find_current_match_index(matches, {cursor_line, cursor_col}) do
    idx =
      Enum.find_index(matches, fn %{line: line, col: col} ->
        line > cursor_line or (line == cursor_line and col >= cursor_col)
      end)

    (idx || 0) + 1
  end
end

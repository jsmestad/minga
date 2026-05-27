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

  def build(%EditorSearch{gui_search: %{} = gs, last_pattern: pattern}, active_buffer) do
    search_opts = [
      case_sensitive: Map.get(gs, :case_sensitive, true),
      whole_word: Map.get(gs, :whole_word, false),
      regex: Map.get(gs, :regex, false)
    ]

    {match_count, current_index} = compute_search_stats(active_buffer, pattern, search_opts)

    %SearchStateModel{
      active: true,
      match_count: match_count,
      current_index: current_index,
      case_sensitive: Map.get(gs, :case_sensitive, true),
      whole_word: Map.get(gs, :whole_word, false),
      regex: Map.get(gs, :regex, false),
      replace_mode: Map.get(gs, :replace_mode, false)
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
    match_count = length(all_matches)

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

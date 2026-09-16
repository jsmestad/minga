defmodule MingaEditor.RenderModel.UI.SearchStateBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.SearchState, as: SearchStateModel
  alias MingaEditor.State.Search.Projection

  @spec build(Projection.t()) :: SearchStateModel.t()
  def build(%Projection{} = search) do
    %SearchStateModel{
      active: search.active,
      query: search.query,
      session_id: search.session_id,
      acknowledged_edit_seq: search.acknowledged_edit_seq,
      match_count: search.match_count,
      current_index: search.current_index,
      case_sensitive: search.case_sensitive,
      whole_word: search.whole_word,
      regex: search.regex,
      replace_mode: search.replace_mode,
      status: search.status
    }
  end
end

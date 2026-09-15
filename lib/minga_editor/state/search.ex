defmodule MingaEditor.State.Search do
  @moduledoc """
  Groups search-related fields from EditorState.

  Tracks the last search pattern and direction (for `n`/`N` repeat),
  the pending project-wide search query (read off the editor path by the
  project search picker source), and the complete GUI search session.
  """

  @typedoc "Retained authoritative GUI search session, including inactive sessions."
  @type gui_search :: %{
          active: boolean(),
          session_id: pos_integer(),
          acknowledged_edit_seq: non_neg_integer(),
          query: String.t(),
          replace_mode: boolean(),
          case_sensitive: boolean(),
          whole_word: boolean(),
          regex: boolean()
        }

  @type t :: %__MODULE__{
          last_pattern: String.t() | nil,
          last_direction: Minga.Editing.Search.direction(),
          project_query: String.t() | nil,
          gui_search: gui_search() | nil
        }

  defstruct last_pattern: nil,
            last_direction: :forward,
            project_query: nil,
            gui_search: nil

  @doc "Records the last search pattern and direction."
  @spec record(t(), String.t(), Minga.Editing.Search.direction()) :: t()
  def record(%__MODULE__{} = s, pattern, direction) do
    %{s | last_pattern: pattern, last_direction: direction}
  end

  @doc "Records just the last search pattern (keeps existing direction)."
  @spec record_pattern(t(), String.t()) :: t()
  def record_pattern(%__MODULE__{} = s, pattern) do
    %{s | last_pattern: pattern}
  end

  @doc "Sets just the last search direction."
  @spec set_last_direction(t(), Minga.Editing.Search.direction()) :: t()
  def set_last_direction(%__MODULE__{} = s, direction) do
    %{s | last_direction: direction}
  end

  @doc "Stores the pending project-wide search query for the async picker source."
  @spec set_project_query(t(), String.t()) :: t()
  def set_project_query(%__MODULE__{} = s, query) when is_binary(query) do
    %{s | project_query: query}
  end

  @doc "Starts a fresh GUI search session while preserving its query and options."
  @spec focus_gui_search(t(), boolean()) :: t()
  def focus_gui_search(%__MODULE__{gui_search: nil} = s, replace_mode) do
    %{
      s
      | gui_search: %{
          active: true,
          session_id: 1,
          acknowledged_edit_seq: 0,
          query: initial_gui_query(s.last_pattern),
          replace_mode: replace_mode,
          case_sensitive: false,
          whole_word: false,
          regex: false
        }
    }
  end

  def focus_gui_search(%__MODULE__{gui_search: gui_search} = s, replace_mode) do
    gui_search = %{
      gui_search
      | active: true,
        session_id: next_session_id(gui_search.session_id),
        acknowledged_edit_seq: 0,
        replace_mode: replace_mode
    }

    %{s | gui_search: gui_search}
  end

  @doc "Accepts a complete native query edit only for the active session and a newer sequence."
  @spec apply_gui_search_edit(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          boolean(),
          boolean(),
          boolean()
        ) :: {:accepted, t()} | {:stale, t()}
  def apply_gui_search_edit(
        %__MODULE__{
          gui_search:
            %{
              active: true,
              session_id: session_id,
              acknowledged_edit_seq: acknowledged_edit_seq
            } = gui_search
        } = s,
        session_id,
        edit_seq,
        query,
        case_sensitive,
        whole_word,
        regex
      )
      when is_binary(query) and edit_seq > acknowledged_edit_seq do
    gui_search = %{
      gui_search
      | acknowledged_edit_seq: edit_seq,
        query: query,
        case_sensitive: case_sensitive,
        whole_word: whole_word,
        regex: regex
    }

    {:accepted, %{s | gui_search: gui_search, last_pattern: query, last_direction: :forward}}
  end

  def apply_gui_search_edit(
        %__MODULE__{} = s,
        _session_id,
        _edit_seq,
        _query,
        _case_sensitive,
        _whole_word,
        _regex
      ),
      do: {:stale, s}

  @doc "Dismisses the GUI search toolbar."
  @spec dismiss_gui_search(t()) :: t()
  def dismiss_gui_search(%__MODULE__{gui_search: %{} = gui_search} = s),
    do: %{s | gui_search: %{gui_search | active: false}}

  def dismiss_gui_search(%__MODULE__{} = s), do: s

  @doc "Returns whether the GUI search toolbar is active."
  @spec gui_search_active?(t()) :: boolean()
  def gui_search_active?(%__MODULE__{gui_search: %{active: true}}), do: true
  def gui_search_active?(%__MODULE__{}), do: false

  defp initial_gui_query(nil), do: ""
  defp initial_gui_query(pattern), do: pattern

  defp next_session_id(0xFFFFFFFF), do: 1
  defp next_session_id(session_id), do: session_id + 1
end

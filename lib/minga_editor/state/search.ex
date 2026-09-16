defmodule MingaEditor.State.Search do
  @moduledoc """
  Groups search-related fields from EditorState.

  Tracks the last search pattern and direction (for `n`/`N` repeat),
  the pending project-wide search query (read off the editor path by the
  project search picker source), and the complete GUI search session.
  """

  alias Minga.Editing.Search.Index
  alias MingaEditor.State.Search.Projection
  alias MingaEditor.State.Search.Session

  @typedoc "Retained authoritative GUI search session, including inactive sessions."
  @type gui_search :: Session.t()

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
    %{s | gui_search: Session.new(initial_gui_query(s.last_pattern), replace_mode)}
  end

  def focus_gui_search(%__MODULE__{gui_search: %Session{} = session} = s, replace_mode) do
    %{s | gui_search: Session.focus(session, replace_mode)}
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
        %__MODULE__{gui_search: %Session{} = session} = s,
        session_id,
        edit_seq,
        query,
        case_sensitive,
        whole_word,
        regex
      ) do
    case Session.accept_edit(
           session,
           session_id,
           edit_seq,
           query,
           case_sensitive,
           whole_word,
           regex
         ) do
      {:accepted, session} ->
        {:accepted, %{s | gui_search: session, last_pattern: query, last_direction: :forward}}

      :stale ->
        {:stale, s}
    end
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
  def dismiss_gui_search(%__MODULE__{gui_search: %Session{} = session} = s),
    do: %{s | gui_search: Session.dismiss(session)}

  def dismiss_gui_search(%__MODULE__{} = s), do: s

  @doc "Returns whether the GUI search toolbar is active."
  @spec gui_search_active?(t()) :: boolean()
  def gui_search_active?(%__MODULE__{gui_search: %Session{active: true}}), do: true
  def gui_search_active?(%__MODULE__{}), do: false

  @doc "Targets the active GUI session at a buffer and marks its build pending."
  @spec begin_gui_build(t(), pid()) :: t()
  def begin_gui_build(%__MODULE__{gui_search: %Session{} = session} = search, buffer),
    do: %{search | gui_search: Session.begin_build(session, buffer)}

  @doc "Accepts a fully built index only for the exact live search revision."
  @spec accept_gui_index(
          t(),
          non_neg_integer(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          Index.t()
        ) :: {:accepted, t()} | {:stale, t()}
  def accept_gui_index(
        %__MODULE__{gui_search: %Session{} = session} = search,
        revision,
        buffer,
        version,
        sequence,
        index
      ) do
    case Session.accept_index(session, revision, buffer, version, sequence, index) do
      {:accepted, session} -> {:accepted, %{search | gui_search: session}}
      :stale -> {:stale, search}
    end
  end

  @doc "Installs an exact line-local incremental index update."
  @spec accept_gui_incremental(t(), non_neg_integer(), non_neg_integer(), Index.t()) :: t()
  def accept_gui_incremental(
        %__MODULE__{gui_search: %Session{} = session} = search,
        version,
        sequence,
        index
      ),
      do: %{search | gui_search: Session.accept_incremental(session, version, sequence, index)}

  @doc "Invalidates the accepted revision and retains prior results only for pending display."
  @spec rebuild_gui_search(t(), Minga.Buffer.EditDelta.t() | nil) :: t()
  def rebuild_gui_search(%__MODULE__{gui_search: %Session{} = session} = search, delta),
    do: %{search | gui_search: Session.rebuild(session, delta)}

  @doc "Records an explicit asynchronous search failure for the exact live request."
  @spec fail_gui_search(t(), non_neg_integer(), pid(), String.t()) ::
          {:accepted, t()} | {:stale, t()}
  def fail_gui_search(
        %__MODULE__{
          gui_search: %Session{active: true, revision: revision, target_buffer: buffer} = session
        } = search,
        revision,
        buffer,
        reason
      ),
      do: {:accepted, %{search | gui_search: Session.fail(session, reason)}}

  def fail_gui_search(%__MODULE__{} = search, _revision, _buffer, _reason),
    do: {:stale, search}

  @doc "Returns the bounded renderer projection without copying the index."
  @spec render_snapshot(t(), pid() | nil, Minga.Editing.Search.position()) :: Projection.t()
  def render_snapshot(%__MODULE__{gui_search: nil}, _buffer, _cursor) do
    %Projection{
      active: false,
      query: "",
      session_id: 0,
      acknowledged_edit_seq: 0,
      match_count: 0,
      current_index: 0,
      case_sensitive: false,
      whole_word: false,
      regex: false,
      replace_mode: false,
      status: :ready
    }
  end

  def render_snapshot(%__MODULE__{gui_search: session}, buffer, cursor),
    do: Session.projection(session, buffer, cursor)

  @doc "Returns a ready index only at the exact active buffer revision."
  @spec ready_gui_index(t(), pid(), {non_neg_integer(), non_neg_integer()}) ::
          {:ok, Index.t()} | :stale
  def ready_gui_index(%__MODULE__{gui_search: %Session{} = session}, buffer, revision),
    do: Session.ready_index(session, buffer, revision)

  def ready_gui_index(%__MODULE__{}, _buffer, _revision), do: :stale

  @doc "Returns the active GUI query options."
  @spec gui_options(t()) :: Minga.Editing.Search.search_opts()
  def gui_options(%__MODULE__{gui_search: %Session{} = session}), do: Session.options(session)
  def gui_options(%__MODULE__{}), do: []

  defp initial_gui_query(nil), do: ""
  defp initial_gui_query(pattern), do: pattern
end

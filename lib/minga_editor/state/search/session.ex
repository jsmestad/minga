defmodule MingaEditor.State.Search.Session do
  @moduledoc false

  alias Minga.Buffer.EditDelta
  alias Minga.Editing.Search.Index
  alias MingaEditor.State.Search.Projection

  @type result ::
          :loading | {:ready, Index.t()} | {:rebuilding, Index.t()} | {:failed, String.t()}

  @enforce_keys [
    :active,
    :session_id,
    :acknowledged_edit_seq,
    :query,
    :replace_mode,
    :case_sensitive,
    :whole_word,
    :regex,
    :revision,
    :target_buffer,
    :accepted_version,
    :accepted_sequence,
    :result,
    :pending_deltas
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          active: boolean(),
          session_id: pos_integer(),
          acknowledged_edit_seq: non_neg_integer(),
          query: String.t(),
          replace_mode: boolean(),
          case_sensitive: boolean(),
          whole_word: boolean(),
          regex: boolean(),
          revision: non_neg_integer(),
          target_buffer: pid() | nil,
          accepted_version: non_neg_integer() | nil,
          accepted_sequence: non_neg_integer() | nil,
          result: result(),
          pending_deltas: [EditDelta.t()]
        }

  @spec new(String.t(), boolean()) :: t()
  def new(query, replace_mode) do
    %__MODULE__{
      active: true,
      session_id: 1,
      acknowledged_edit_seq: 0,
      query: query,
      replace_mode: replace_mode,
      case_sensitive: false,
      whole_word: false,
      regex: false,
      revision: 1,
      target_buffer: nil,
      accepted_version: nil,
      accepted_sequence: nil,
      result: :loading,
      pending_deltas: []
    }
  end

  @spec focus(t(), boolean()) :: t()
  def focus(%__MODULE__{active: true} = session, replace_mode) do
    %{
      session
      | session_id: next_session_id(session.session_id),
        acknowledged_edit_seq: 0,
        replace_mode: replace_mode
    }
  end

  def focus(%__MODULE__{active: false} = session, replace_mode) do
    %{
      session
      | active: true,
        session_id: next_session_id(session.session_id),
        acknowledged_edit_seq: 0,
        replace_mode: replace_mode,
        revision: session.revision + 1,
        target_buffer: nil,
        accepted_version: nil,
        accepted_sequence: nil,
        result: :loading,
        pending_deltas: []
    }
  end

  @spec accept_edit(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          boolean(),
          boolean(),
          boolean()
        ) ::
          {:accepted, t()} | :stale
  def accept_edit(
        %__MODULE__{
          active: true,
          session_id: session_id,
          acknowledged_edit_seq: acknowledged_edit_seq
        } = session,
        session_id,
        edit_seq,
        query,
        case_sensitive,
        whole_word,
        regex
      )
      when is_binary(query) and edit_seq > acknowledged_edit_seq do
    {:accepted,
     %{
       session
       | acknowledged_edit_seq: edit_seq,
         query: query,
         case_sensitive: case_sensitive,
         whole_word: whole_word,
         regex: regex,
         revision: session.revision + 1,
         accepted_version: nil,
         accepted_sequence: nil,
         result: prior_result(session.result),
         pending_deltas: []
     }}
  end

  def accept_edit(%__MODULE__{}, _session_id, _edit_seq, _query, _case, _word, _regex),
    do: :stale

  @spec begin_build(t(), pid()) :: t()
  def begin_build(%__MODULE__{} = session, buffer) when is_pid(buffer) do
    %{
      session
      | target_buffer: buffer,
        accepted_version: nil,
        accepted_sequence: nil,
        result: prior_result(session.result),
        pending_deltas: []
    }
  end

  @spec accept_index(
          t(),
          non_neg_integer(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          Index.t()
        ) ::
          {:accepted, t()} | :stale
  def accept_index(
        %__MODULE__{active: true, revision: revision, target_buffer: buffer} = session,
        revision,
        buffer,
        version,
        sequence,
        %Index{} = index
      ) do
    {:accepted,
     %{
       session
       | accepted_version: version,
         accepted_sequence: sequence,
         result: {:ready, index},
         pending_deltas: []
     }}
  end

  def accept_index(%__MODULE__{}, _revision, _buffer, _version, _sequence, %Index{}),
    do: :stale

  @spec accept_incremental(t(), non_neg_integer(), non_neg_integer(), Index.t()) :: t()
  def accept_incremental(%__MODULE__{} = session, version, sequence, %Index{} = index) do
    %{
      session
      | accepted_version: version,
        accepted_sequence: sequence,
        result: {:ready, index},
        pending_deltas: []
    }
  end

  @spec rebuild(t(), EditDelta.t() | nil) :: t()
  def rebuild(%__MODULE__{} = session, delta) do
    pending =
      if is_struct(delta, EditDelta),
        do: append_pending_delta(session.pending_deltas, delta),
        else: []

    %{
      session
      | revision: session.revision + 1,
        accepted_version: nil,
        accepted_sequence: nil,
        result: prior_result(session.result),
        pending_deltas: pending
    }
  end

  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{} = session, reason) do
    %{
      session
      | accepted_version: nil,
        accepted_sequence: nil,
        result: {:failed, reason},
        pending_deltas: []
    }
  end

  @spec dismiss(t()) :: t()
  def dismiss(%__MODULE__{} = session) do
    %{
      session
      | active: false,
        revision: session.revision + 1,
        target_buffer: nil,
        pending_deltas: []
    }
  end

  @spec projection(t(), pid() | nil, {non_neg_integer(), non_neg_integer()}) :: Projection.t()
  def projection(%__MODULE__{} = session, active_buffer, cursor) do
    {status, index} = projection_result(session, active_buffer)

    %Projection{
      active: session.active,
      query: session.query,
      session_id: session.session_id,
      acknowledged_edit_seq: session.acknowledged_edit_seq,
      match_count: if(index, do: Index.count(index), else: 0),
      current_index: if(index, do: Index.current_ordinal(index, cursor), else: 0),
      case_sensitive: session.case_sensitive,
      whole_word: session.whole_word,
      regex: session.regex,
      replace_mode: session.replace_mode,
      status: status
    }
  end

  @spec ready_index(t(), pid(), {non_neg_integer(), non_neg_integer()}) ::
          {:ok, Index.t()} | :stale
  def ready_index(
        %__MODULE__{
          active: true,
          target_buffer: buffer,
          accepted_version: version,
          accepted_sequence: sequence,
          result: {:ready, %Index{} = index}
        },
        buffer,
        {version, sequence}
      ),
      do: {:ok, index}

  def ready_index(%__MODULE__{}, _buffer, _revision), do: :stale

  @spec options(t()) :: Minga.Editing.Search.search_opts()
  def options(%__MODULE__{} = session) do
    [
      case_sensitive: session.case_sensitive,
      whole_word: session.whole_word,
      regex: session.regex
    ]
  end

  @spec prior_result(result()) :: result()
  defp prior_result({:ready, index}), do: {:rebuilding, index}
  defp prior_result({:rebuilding, index}), do: {:rebuilding, index}
  defp prior_result(_result), do: :loading

  @spec projection_result(t(), pid() | nil) :: {Projection.status(), Index.t() | nil}
  defp projection_result(%__MODULE__{active: false}, _active_buffer), do: {:ready, nil}

  defp projection_result(%__MODULE__{target_buffer: target}, active_buffer)
       when target != active_buffer,
       do: {:rebuilding, nil}

  defp projection_result(%__MODULE__{result: :loading}, _active_buffer), do: {:loading, nil}

  defp projection_result(%__MODULE__{result: {:ready, index}}, _active_buffer),
    do: {:ready, index}

  defp projection_result(%__MODULE__{result: {:rebuilding, index}}, _active_buffer),
    do: {:rebuilding, index}

  defp projection_result(%__MODULE__{result: {:failed, _reason}}, _active_buffer),
    do: {:failed, nil}

  @spec append_pending_delta([EditDelta.t()], EditDelta.t()) :: [EditDelta.t()]
  defp append_pending_delta([], delta), do: [delta]
  defp append_pending_delta([delta | rest], next), do: [delta | append_pending_delta(rest, next)]

  @spec next_session_id(pos_integer()) :: pos_integer()
  defp next_session_id(0xFFFFFFFF), do: 1
  defp next_session_id(session_id), do: session_id + 1
end

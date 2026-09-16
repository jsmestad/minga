defmodule MingaEditor.GuiSearchWorkflow do
  @moduledoc "Owns GUI Find admission, navigation, replacement, and buffer-change reconciliation."

  alias Minga.Buffer
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RenderSnapshot
  alias Minga.Editing.Search.Index
  alias Minga.Events.BufferChangedEvent
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.GuiSearchBuild
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Search
  alias MingaEditor.State.Search.Session

  @type state :: EditorState.t()

  @doc "Focuses Find or Replace and admits matching for the active buffer."
  @spec focus(state(), boolean()) :: state()
  def focus(%EditorState{} = state, replace_mode) do
    active? = Search.gui_search_active?(state.workspace.search)

    state = put_search(state, Search.focus_gui_search(state.workspace.search, replace_mode))

    if active?, do: state, else: build_for_active_buffer(state, true)
  end

  @doc "Accepts one correlated native query/options edit and admits its replacement build."
  @spec replace_query(
          state(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          boolean(),
          boolean(),
          boolean()
        ) :: state()
  def replace_query(
        %EditorState{} = state,
        session_id,
        edit_seq,
        query,
        case_sensitive,
        whole_word,
        regex
      ) do
    case Search.apply_gui_search_edit(
           state.workspace.search,
           session_id,
           edit_seq,
           query,
           case_sensitive,
           whole_word,
           regex
         ) do
      {:accepted, search} ->
        state
        |> put_search(search)
        |> build_for_active_buffer(true)

      {:stale, _search} ->
        state
    end
  end

  @doc "Retargets an active GUI search after the active buffer changes."
  @spec active_buffer_changed(state()) :: state()
  def active_buffer_changed(%EditorState{} = state) do
    if Search.gui_search_active?(state.workspace.search),
      do: build_for_active_buffer(state, false),
      else: state
  end

  @doc "Applies an exact line-local update or schedules one latest full rebuild."
  @spec buffer_changed(state(), BufferChangedEvent.t()) :: state()
  def buffer_changed(
        %EditorState{
          workspace: %{
            search: %Search{
              gui_search: %Session{
                active: true,
                target_buffer: buffer,
                accepted_version: accepted_version,
                accepted_sequence: accepted_sequence,
                result: {:ready, %Index{} = index}
              }
            }
          }
        } = state,
        %BufferChangedEvent{
          buffer: buffer,
          delta: %EditDelta{} = delta,
          version: version,
          sequence: sequence
        }
      )
      when is_integer(accepted_version) and is_integer(accepted_sequence) and
             sequence == accepted_sequence + 1 and is_integer(version) do
    apply_incremental(state, buffer, index, delta, version, sequence)
  end

  def buffer_changed(
        %EditorState{
          workspace: %{
            search: %Search{
              gui_search: %Session{
                active: true,
                target_buffer: buffer,
                accepted_sequence: accepted_sequence
              }
            }
          }
        } = state,
        %BufferChangedEvent{buffer: buffer, sequence: sequence}
      )
      when is_integer(accepted_sequence) and sequence <= accepted_sequence,
      do: state

  def buffer_changed(
        %EditorState{
          workspace: %{search: %Search{gui_search: %Session{active: true, target_buffer: buffer}}}
        } = state,
        %BufferChangedEvent{buffer: buffer, delta: delta}
      ) do
    rebuild(state, delta)
  end

  def buffer_changed(%EditorState{} = state, %BufferChangedEvent{}), do: state

  @doc "Moves to the next accepted indexed match without reading document content."
  @spec navigate(state(), Minga.Editing.Search.direction()) :: state()
  def navigate(%EditorState{workspace: %{buffers: %{active: buffer}}} = state, direction)
      when is_pid(buffer) and direction in [:forward, :backward] do
    with revision when revision != :unavailable <- current_revision(buffer),
         {:ok, index} <- Search.ready_gui_index(state.workspace.search, buffer, revision),
         %{line: line, col: col} <- Index.next(index, Buffer.cursor(buffer), direction) do
      Buffer.move_to(buffer, {line, col})
      state
    else
      _reason -> state
    end
  end

  def navigate(%EditorState{} = state, _direction), do: state

  @doc "Replaces the exact accepted match under the cursor."
  @spec replace(state(), String.t()) :: state()
  def replace(%EditorState{workspace: %{buffers: %{active: buffer}}} = state, replacement)
      when is_pid(buffer) and is_binary(replacement) do
    with {version, _sequence} = revision <- current_revision(buffer),
         {:ok, index} <- Search.ready_gui_index(state.workspace.search, buffer, revision),
         %{line: line, col: col, length: length} <- Index.match_at(index, Buffer.cursor(buffer)),
         {:ok, new_version} <-
           Buffer.replace_byte_range_if_version(buffer, version, {line, col}, length, replacement) do
      finish_replace(state, buffer, index, line, col, length, replacement, new_version)
    else
      {:error, :read_only} -> NoticeWorkflow.publish(state, "Buffer is read-only")
      _reason -> stale_match(state)
    end
  end

  def replace(%EditorState{} = state, _replacement), do: state

  @doc "Replaces every match only when the accepted index matches the atomic buffer revision."
  @spec replace_all(state(), String.t()) :: state()
  def replace_all(%EditorState{workspace: %{buffers: %{active: buffer}}} = state, replacement)
      when is_pid(buffer) and is_binary(replacement) do
    with revision when revision != :unavailable <- current_revision(buffer),
         {:ok, _index} <- Search.ready_gui_index(state.workspace.search, buffer, revision),
         %Session{query: query} when query != "" <- state.workspace.search.gui_search,
         {content, version} <- Buffer.content_with_version(buffer),
         {^version, _sequence} <- revision do
      {new_content, count} =
        Minga.Editing.substitute(
          content,
          query,
          replacement,
          true,
          Search.gui_options(state.workspace.search)
        )

      if count > 0 do
        Buffer.replace_content(buffer, new_content)
        NoticeWorkflow.publish(state, replacement_message(count))
      else
        NoticeWorkflow.publish(state, "No matches to replace")
      end
    else
      _reason -> stale_match(state)
    end
  end

  def replace_all(%EditorState{} = state, _replacement), do: state

  @doc "Dismisses Find and cancels every queued or running search build."
  @spec dismiss(state()) :: state()
  def dismiss(%EditorState{} = state) do
    _result = EffectScheduler.cancel_resource(state.effect_scheduler, :gui_search)
    put_search(state, Search.dismiss_gui_search(state.workspace.search))
  end

  @spec build_for_active_buffer(state(), boolean()) :: state()
  defp build_for_active_buffer(
         %EditorState{workspace: %{buffers: %{active: buffer}}} = state,
         select_first?
       )
       when is_pid(buffer) do
    %Session{} = session = state.workspace.search.gui_search
    search = Search.begin_gui_build(state.workspace.search, buffer)
    state = put_search(state, search)

    request =
      GuiSearchBuild.request(
        buffer,
        session.query,
        Search.gui_options(search),
        session.revision,
        select_first?
      )

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _admission} -> state
      {:error, reason} -> fail_admission(state, session.revision, buffer, reason)
    end
  end

  defp build_for_active_buffer(%EditorState{} = state, _select_first?) do
    _result = EffectScheduler.cancel_resource(state.effect_scheduler, :gui_search)
    state
  end

  @spec apply_incremental(
          state(),
          pid(),
          Index.t(),
          EditDelta.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: state()
  defp apply_incremental(state, buffer, index, delta, version, sequence) do
    {first_line, last_line} = EditDelta.affected_line_range([delta])
    count = last_line - first_line + 1

    case Buffer.render_lines(buffer, version, first_line, count) do
      {:ok,
       %RenderSnapshot{
         version: ^version,
         change_sequence: ^sequence,
         first_line: ^first_line,
         lines: lines
       }} ->
        updated = Index.apply_edits(index, [delta], first_line, lines)

        put_search(
          state,
          Search.accept_gui_incremental(state.workspace.search, version, sequence, updated)
        )

      _stale ->
        rebuild(state, delta)
    end
  catch
    :exit, _reason -> rebuild(state, delta)
  end

  @spec finish_replace(
          state(),
          pid(),
          Index.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          non_neg_integer()
        ) :: state()
  defp finish_replace(state, buffer, index, line, col, old_length, replacement, version) do
    {_version, sequence} = Buffer.sync_revision(buffer)

    case Buffer.render_lines(buffer, version, line, 1) do
      {:ok,
       %RenderSnapshot{
         version: ^version,
         change_sequence: ^sequence,
         first_line: ^line,
         lines: lines
       }} ->
        delta =
          EditDelta.replacement(
            0,
            old_length,
            {line, col},
            {line, col + old_length},
            replacement,
            {line, col + byte_size(replacement)}
          )

        updated = Index.apply_edits(index, [delta], line, lines)
        search = Search.accept_gui_incremental(state.workspace.search, version, sequence, updated)
        state = put_search(state, search)
        advance_after_replace(state, buffer, updated, old_length)

      _stale ->
        rebuild(state, nil)
    end
  catch
    :exit, _reason -> rebuild(state, nil)
  end

  @spec advance_after_replace(state(), pid(), Index.t(), non_neg_integer()) :: state()
  defp advance_after_replace(state, buffer, index, old_length) do
    cursor = Buffer.cursor(buffer)

    if old_length > 0 and Index.match_at(index, cursor) != nil do
      state
    else
      case Index.next(index, cursor, :forward) do
        nil ->
          state

        %{line: line, col: col} ->
          Buffer.move_to(buffer, {line, col})
          state
      end
    end
  end

  @spec rebuild(state(), EditDelta.t() | nil) :: state()
  defp rebuild(%EditorState{} = state, delta) do
    state
    |> put_search(Search.rebuild_gui_search(state.workspace.search, delta))
    |> build_for_active_buffer(false)
  end

  @spec fail_admission(state(), non_neg_integer(), pid(), term()) :: state()
  defp fail_admission(state, revision, buffer, reason) do
    message = "search scheduler rejected work: #{inspect(reason)}"

    case Search.fail_gui_search(state.workspace.search, revision, buffer, message) do
      {:accepted, search} ->
        NoticeWorkflow.publish(put_search(state, search), "Find failed: #{message}")

      {:stale, _search} ->
        state
    end
  end

  @spec current_revision(pid()) :: {non_neg_integer(), non_neg_integer()} | :unavailable
  defp current_revision(buffer) do
    Buffer.sync_revision(buffer)
  catch
    :exit, _reason -> :unavailable
  end

  @spec put_search(state(), Search.t()) :: state()
  defp put_search(state, search) do
    %{state | workspace: SessionState.set_search(state.workspace, search)}
  end

  @spec stale_match(state()) :: state()
  defp stale_match(state),
    do:
      NoticeWorkflow.publish(
        state,
        "Search results changed; wait for Find to finish and try again"
      )

  @spec replacement_message(pos_integer()) :: String.t()
  defp replacement_message(1), do: "1 replacement"
  defp replacement_message(count), do: "#{count} replacements"
end

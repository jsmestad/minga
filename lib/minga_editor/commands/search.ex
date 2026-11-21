defmodule MingaEditor.Commands.Search do
  @moduledoc """
  Search commands: incremental search, confirm/cancel, next/prev match, and
  word-under-cursor search.

  Successful search jumps mark the window's authoritative-scroll marker (#2652)
  in their success branch, so a hit landing on the same committed top still
  discards a frontend-held local scroll offset. Failed searches (no pattern, no
  match, no word under cursor) deliberately do not mark: a no-op must never
  discard the user's local scroll. See
  `MingaEditor.Commands.@authoritative_scroll_commands` for the dispatch-marked
  set.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias Minga.Editing.Search.Match
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.TodoSearchWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Search, as: SearchData
  alias MingaEditor.Window
  alias Minga.Mode
  alias Minga.Mode.CommandState
  alias Minga.Mode.SearchState
  alias Minga.Mode.SubstituteConfirmState

  @type state :: EditorState.t()

  @command_specs [
    {:incremental_search, "Start incremental search", true},
    {:confirm_search, "Confirm search", true},
    {:cancel_search, "Cancel search", true},
    {:search_next, "Next search match", true},
    {:search_prev, "Previous search match", true},
    {:search_word_under_cursor_forward, "Search word under cursor (forward)", true},
    {:search_word_under_cursor_backward, "Search word under cursor (backward)", true},
    {:confirm_project_search, "Confirm project search", true},
    {:substitute_confirm_advance, "Advance substitute confirmation", true},
    {:apply_substitute_confirm, "Apply substitute and confirm", true},
    {:use_selection_for_find, "Use selection for Find (Cmd+E)", true}
  ]

  @spec execute(state(), Mode.command()) :: state()

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{mode_state: %SearchState{} = ms}}} =
          state,
        :incremental_search
      ) do
    if ms.input == "" do
      Buffer.move_to(buf, ms.original_cursor)
      state
    else
      content = Buffer.content(buf)

      case Minga.Editing.search_next(content, ms.input, ms.original_cursor, ms.direction) do
        nil ->
          state

        {line, col} ->
          Buffer.move_to(buf, {line, col})

          %{
            state
            | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
          }
      end
    end
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{mode_state: %SearchState{} = ms}}} =
          state,
        :confirm_search
      ) do
    buf
    |> Buffer.content()
    |> Minga.Editing.search_next(ms.input, ms.original_cursor, ms.direction)
    |> apply_search_result(state, buf, ms.input, ms.direction)
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{mode_state: %SearchState{} = ms}}} =
          state,
        :cancel_search
      ) do
    Buffer.move_to(buf, ms.original_cursor)
    state
  end

  def execute(
        %{
          workspace: %{
            buffers: %{active: buf},
            search: %{last_pattern: pattern, last_direction: dir}
          }
        } = state,
        :search_next
      )
      when is_binary(pattern) do
    content = Buffer.content(buf)
    cursor = Buffer.cursor(buf)

    case Minga.Editing.search_next(content, pattern, cursor, dir) do
      nil ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "Pattern not found: #{pattern}"
        )

      {line, col} ->
        Buffer.move_to(buf, {line, col})

        state = %{
          state
          | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
        }

        auto_unfold_at(state, line)
    end
  end

  def execute(state, :search_next) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No previous search pattern")
  end

  def execute(
        %{
          workspace: %{
            buffers: %{active: buf},
            search: %{last_pattern: pattern, last_direction: dir}
          }
        } = state,
        :search_prev
      )
      when is_binary(pattern) do
    reverse = if dir == :forward, do: :backward, else: :forward
    content = Buffer.content(buf)
    cursor = Buffer.cursor(buf)

    case Minga.Editing.search_next(content, pattern, cursor, reverse) do
      nil ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "Pattern not found: #{pattern}"
        )

      {line, col} ->
        Buffer.move_to(buf, {line, col})

        state = %{
          state
          | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
        }

        auto_unfold_at(state, line)
    end
  end

  def execute(state, :search_prev) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No previous search pattern")
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, direction)
      when direction in [:search_word_under_cursor_forward, :search_word_under_cursor_backward] do
    {content, cursor} = Buffer.content_and_cursor(buf)
    direction = if direction == :search_word_under_cursor_forward, do: :forward, else: :backward

    case Minga.Editing.search_word_next(content, cursor, direction) do
      nil ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No word under cursor")

      {word, position} ->
        apply_search_result(position, state, buf, word, direction)
    end
  end

  def execute(
        %{workspace: %{editing: %{mode_state: %{input: query}}}} = state,
        :confirm_project_search
      )
      when is_binary(query) and query != "" do
    # Stash the query, then open the picker asynchronously. The actual `rg`/`grep`
    # scan runs off the editor input path inside ProjectSearchSource.async_fetch/1,
    # so confirming a search never blocks the editor on a large repository.
    %{
      state
      | workspace:
          MingaEditor.Session.State.set_search(
            state.workspace,
            SearchData.set_project_query(state.workspace.search, query)
          )
    }
    |> PickerUI.open(MingaEditor.UI.Picker.ProjectSearchSource)
  end

  def execute(state, :confirm_project_search) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Empty search query")
  end

  # Advance cursor to current match during substitute confirm
  def execute(
        %{
          workspace: %{
            buffers: %{active: buf},
            editing: %{mode_state: %SubstituteConfirmState{} = ms}
          }
        } =
          state,
        :substitute_confirm_advance
      ) do
    case SubstituteConfirmState.current_match(ms) do
      %Match{line: line, col: col} -> Buffer.move_to(buf, {line, col})
      nil -> :ok
    end

    state
  end

  def execute(state, :substitute_confirm_advance), do: state

  # Apply accepted substitutions from the leaving mode state, already in :normal.
  def execute(
        %{
          workspace: %{
            buffers: %{active: buf},
            editing: %{mode_state: %SubstituteConfirmState{} = ms}
          }
        } =
          state,
        :apply_substitute_confirm
      ) do
    case SubstituteConfirmState.accepted_matches(ms) do
      [] ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No substitutions made")

      accepted ->
        new_content =
          Minga.Editing.apply_substitutions(ms.original_content, accepted, ms.replacement)

        Buffer.replace_content(buf, new_content)

        cursor_line = SubstituteConfirmState.first_offered_line(ms)
        total_lines = Buffer.line_count(buf)
        safe_line = min(cursor_line, max(0, total_lines - 1))
        Buffer.move_to(buf, {safe_line, 0})

        {_ordinal, total} = SubstituteConfirmState.progress(ms)

        msg =
          case length(accepted) do
            1 -> "1 substitution"
            count -> "#{count} of #{total} substitutions"
          end

        state
        |> record_substitution(ms.pattern)
        |> NoticeWorkflow.publish(msg)
    end
  end

  def execute(state, :apply_substitute_confirm), do: state

  # ── Use selection for Find (Cmd+E) ────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :use_selection_for_find)
      when is_pid(buf) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)
    text = word_at_cursor(gb, cursor)

    if text != "" do
      state = record_search(state, text, :forward)

      if state.frontend.backend in [:gui, :native_gui] and state.frontend.port_manager do
        MingaEditor.Frontend.clipboard_write(state.frontend.port_manager, text, :find)
      end

      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Using \"#{text}\" for Find")
    else
      state
    end
  end

  @doc "Starts substitute confirm mode by finding all matches and transitioning."
  @spec start_substitute_confirm(state(), pid(), String.t(), String.t(), boolean()) :: state()
  def start_substitute_confirm(state, buf, pattern, replacement, global?) do
    content = Buffer.content(buf)
    lines = String.split(content, "\n")
    all_matches = Minga.Editing.search_all_in_range(lines, pattern, 0)

    # When not global, keep only the first match per line
    matches =
      if global? do
        all_matches
      else
        all_matches
        |> Enum.dedup_by(& &1.line)
        |> Enum.sort()
      end

    case matches do
      [] ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "Pattern not found: #{pattern}"
        )

      [%Match{line: first_line, col: first_col} | _] ->
        Buffer.move_to(buf, {first_line, first_col})

        ms = SubstituteConfirmState.new(matches, pattern, replacement, content)

        state = record_substitution(state, pattern)

        %{
          state
          | workspace:
              MingaEditor.Session.State.transition_mode(
                state.workspace,
                :substitute_confirm,
                ms
              )
        }
    end
  end

  @doc "Executes a `:substitute` ex-command against the buffer."
  @spec execute_substitute(state(), pid(), String.t(), String.t(), boolean()) :: state()
  def execute_substitute(state, buf, pattern, replacement, global?) do
    content = Buffer.content(buf)
    {new_content, count} = Minga.Editing.substitute(content, pattern, replacement, global?)

    if count == 0 do
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Pattern not found: #{pattern}")
    else
      cursor = Buffer.cursor(buf)
      Buffer.replace_content(buf, new_content)
      {line, col} = cursor
      total = Buffer.line_count(buf)
      safe_line = min(line, max(0, total - 1))

      safe_col =
        case Buffer.lines(buf, safe_line, 1) do
          [text] when byte_size(text) > 0 ->
            min(col, Unicode.last_grapheme_byte_offset(text))

          _ ->
            0
        end

      Buffer.move_to(buf, {safe_line, safe_col})

      msg = if count == 1, do: "1 substitution", else: "#{count} substitutions"

      state
      |> record_substitution(pattern)
      |> NoticeWorkflow.publish(msg)
    end
  end

  @spec apply_search_result(
          Buffer.position() | nil,
          state(),
          pid(),
          String.t(),
          Minga.Editing.Search.direction()
        ) :: state()
  defp apply_search_result(nil, state, _buf, pattern, direction) do
    state
    |> record_search(pattern, direction)
    |> NoticeWorkflow.publish("Pattern not found: #{pattern}")
  end

  defp apply_search_result({line, col}, state, buf, pattern, direction) do
    Buffer.move_to(buf, {line, col})

    state = %{
      state
      | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
    }

    state
    |> auto_unfold_at(line)
    |> record_search(pattern, direction)
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec record_search(state(), String.t(), Minga.Editing.Search.direction()) :: state()
  defp record_search(%{workspace: workspace} = state, pattern, direction) do
    search = SearchData.record(workspace.search, pattern, direction)
    %{state | workspace: MingaEditor.Session.State.set_search(workspace, search)}
  end

  @spec record_substitution(state(), String.t()) :: state()
  defp record_substitution(%{workspace: workspace} = state, pattern) do
    search = SearchData.record_pattern(workspace.search, pattern)
    %{state | workspace: MingaEditor.Session.State.set_search(workspace, search)}
  end

  @spec project_root() :: term()
  def project_root, do: Minga.Project.resolve_root()

  # Auto-unfold any fold containing the given line in the active window.
  # Handles both per-window folds and decoration folds.
  @spec auto_unfold_at(state(), non_neg_integer()) :: state()
  defp auto_unfold_at(state, line) do
    # Unfold per-window folds
    state =
      case active_foldable_window(state) do
        nil ->
          state

        win ->
          %{
            state
            | workspace:
                MingaEditor.Session.State.set_windows(
                  state.workspace,
                  MingaEditor.State.Windows.unfold_containing(state.workspace.windows, win.id, [
                    line
                  ])
                )
          }
      end

    # Unfold decoration folds
    auto_unfold_decoration_fold(state, line)
  end

  @spec auto_unfold_decoration_fold(state(), non_neg_integer()) :: state()
  defp auto_unfold_decoration_fold(state, line) do
    buf = state.workspace.buffers.active
    open_decoration_fold_at(buf, line)
    state
  catch
    :exit, _ -> state
  end

  @spec open_decoration_fold_at(pid() | nil, non_neg_integer()) :: :ok
  defp open_decoration_fold_at(buf, line) when is_pid(buf) do
    decs = Buffer.decorations(buf)

    case Decorations.fold_region_at(decs, line) do
      %{closed: true, id: id} ->
        Buffer.batch_decorations(buf, fn d -> Decorations.toggle_fold_region(d, id) end)

      _ ->
        :ok
    end
  end

  defp open_decoration_fold_at(_buf, _line), do: :ok

  @spec active_foldable_window(state()) :: Window.t() | nil
  @spec word_at_cursor(Buffer.document(), {non_neg_integer(), non_neg_integer()}) ::
          String.t()
  defp word_at_cursor(gb, cursor) do
    {start_pos, end_pos} = Minga.Editing.select_inner_word(gb, cursor)
    Document.content_between_inclusive(gb, start_pos, end_pos)
  end

  defp active_foldable_window(state) do
    case MingaEditor.Session.State.active_window_struct(state.workspace) do
      %Window{} = win -> if Window.has_folds?(win), do: win
      nil -> nil
    end
  end

  commands(@command_specs)

  command(:search_project, "Search across project files",
    requires_buffer: false,
    execute: fn state ->
      %{
        state
        | workspace:
            MingaEditor.Session.State.transition_mode(
              state.workspace,
              :search_prompt,
              %Minga.Mode.SearchPromptState{}
            )
      }
    end
  )

  command(:search_todos, "Search TODO markers",
    requires_buffer: false,
    execute: &TodoSearchWorkflow.open/1
  )

  command(:search_buffer, "Search in buffer",
    requires_buffer: true,
    execute: fn state ->
      %{
        state
        | workspace:
            MingaEditor.Session.State.transition_mode(state.workspace, :search, %SearchState{
              direction: :forward
            })
      }
    end
  )

  command(:search_and_replace, "Search and replace",
    requires_buffer: true,
    execute: fn state ->
      %{
        state
        | workspace:
            MingaEditor.Session.State.transition_mode(
              state.workspace,
              :command,
              CommandState.new("%s/")
            )
      }
    end
  )
end

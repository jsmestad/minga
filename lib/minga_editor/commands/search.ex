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
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.TodoSearchWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Search, as: SearchData
  alias MingaEditor.Window
  alias Minga.Mode
  alias Minga.Mode.CommandState
  alias Minga.Mode.SearchState

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
    content = Buffer.content(buf)

    case Minga.Editing.search_next(content, ms.input, ms.original_cursor, ms.direction) do
      nil ->
        state
        |> put_in_search(:last_pattern, ms.input)
        |> put_in_search(:last_direction, ms.direction)
        |> then(
          &MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
            &1,
            "Pattern not found: #{ms.input}"
          )
        )

      {line, col} ->
        Buffer.move_to(buf, {line, col})

        state
        |> then(fn state ->
          %{
            state
            | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
          }
        end)
        |> auto_unfold_at(line)
        |> put_in_search(:last_pattern, ms.input)
        |> put_in_search(:last_direction, ms.direction)
    end
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

        state
        |> then(fn state ->
          %{
            state
            | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
          }
        end)
        |> auto_unfold_at(line)
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

        state
        |> then(fn state ->
          %{
            state
            | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
          }
        end)
        |> auto_unfold_at(line)
    end
  end

  def execute(state, :search_prev) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No previous search pattern")
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, direction)
      when direction in [:search_word_under_cursor_forward, :search_word_under_cursor_backward] do
    {content, cursor} = Buffer.content_and_cursor(buf)
    tmp_buf = Document.new(content)
    direction = if direction == :search_word_under_cursor_forward, do: :forward, else: :backward

    case Minga.Editing.word_under_cursor(tmp_buf, cursor) do
      nil ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No word under cursor")

      word ->
        execute_word_search(state, buf, content, cursor, word, direction)
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
            editing: %{mode_state: %Minga.Mode.SubstituteConfirmState{} = ms}
          }
        } =
          state,
        :substitute_confirm_advance
      ) do
    case Enum.at(ms.matches, ms.current) do
      %Minga.Editing.Search.Match{line: line, col: col} -> Buffer.move_to(buf, {line, col})
      _ -> :ok
    end

    state
  end

  def execute(state, :substitute_confirm_advance), do: state

  # Apply accepted substitutions from confirm mode
  def execute(
        %{
          workspace: %{
            buffers: %{active: buf},
            editing: %{mode_state: %Minga.Mode.SubstituteConfirmState{} = ms}
          }
        } =
          state,
        :apply_substitute_confirm
      ) do
    accepted_set = MapSet.new(ms.accepted)
    accepted_count = MapSet.size(accepted_set)
    total = Enum.count(ms.matches)

    if accepted_count == 0 do
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No substitutions made")
    else
      # Apply replacements in reverse order to preserve positions
      sorted_indices =
        ms.accepted
        |> Enum.sort(:desc)

      new_content =
        Enum.reduce(sorted_indices, ms.original_content, fn idx, content ->
          %Minga.Editing.Search.Match{line: line, col: col, length: len} =
            Enum.at(ms.matches, idx)

          replace_match(content, line, col, len, ms.replacement)
        end)

      Buffer.replace_content(buf, new_content)

      # Restore cursor to a safe position
      cursor_line = hd(ms.matches).line
      total_lines = Buffer.line_count(buf)
      safe_line = min(cursor_line, max(0, total_lines - 1))
      Buffer.move_to(buf, {safe_line, 0})

      msg =
        if accepted_count == 1,
          do: "1 substitution",
          else: "#{accepted_count} of #{total} substitutions"

      state
      |> put_in_search(:last_pattern, ms.pattern)
      |> then(&MingaEditor.Shell.Traditional.NoticeWorkflow.publish(&1, msg))
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
      state =
        %{
          state
          | workspace:
              MingaEditor.Session.State.set_search(
                state.workspace,
                (&SearchData.record(&1, text, :forward)).(state.workspace.search)
              )
        }

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
        |> Enum.group_by(fn %Minga.Editing.Search.Match{line: line} -> line end)
        |> Enum.flat_map(fn {_line, line_matches} -> [hd(line_matches)] end)
        |> Enum.sort()
      end

    case matches do
      [] ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "Pattern not found: #{pattern}"
        )

      _ ->
        %Minga.Editing.Search.Match{line: first_line, col: first_col} = hd(matches)
        Buffer.move_to(buf, {first_line, first_col})

        ms = %Minga.Mode.SubstituteConfirmState{
          matches: matches,
          pattern: pattern,
          replacement: replacement,
          original_content: content
        }

        state
        |> put_in_search(:last_pattern, pattern)
        |> then(fn state ->
          %{
            state
            | workspace:
                MingaEditor.Session.State.transition_mode(
                  state.workspace,
                  :substitute_confirm,
                  ms
                )
          }
        end)
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
      |> put_in_search(:last_pattern, pattern)
      |> then(&MingaEditor.Shell.Traditional.NoticeWorkflow.publish(&1, msg))
    end
  end

  defp execute_word_search(state, buf, content, cursor, word, direction) do
    content
    |> Minga.Editing.search_next(word, cursor, direction)
    |> apply_word_search(state, buf, word, direction)
  end

  defp apply_word_search(nil, state, _buf, word, direction),
    do: word_search_not_found(state, word, direction)

  defp apply_word_search({line, col}, state, buf, word, direction),
    do: word_search_found(state, buf, word, direction, line, col)

  defp word_search_not_found(state, word, direction) do
    state
    |> put_in_search(:last_pattern, word)
    |> put_in_search(:last_direction, direction)
    |> then(
      &MingaEditor.Shell.Traditional.NoticeWorkflow.publish(&1, "Pattern not found: #{word}")
    )
  end

  defp word_search_found(state, buf, word, direction, line, col) do
    Buffer.move_to(buf, {line, col})

    state
    |> then(fn state ->
      %{
        state
        | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
      }
    end)
    |> auto_unfold_at(line)
    |> put_in_search(:last_pattern, word)
    |> put_in_search(:last_direction, direction)
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec put_in_search(state(), atom(), term()) :: state()
  defp put_in_search(state, :last_pattern, value) do
    %{
      state
      | workspace:
          MingaEditor.Session.State.set_search(
            state.workspace,
            (&SearchData.record_pattern(&1, value)).(state.workspace.search)
          )
    }
  end

  defp put_in_search(state, :last_direction, value) do
    %{
      state
      | workspace:
          MingaEditor.Session.State.set_search(
            state.workspace,
            (&SearchData.set_last_direction(&1, value)).(state.workspace.search)
          )
    }
  end

  # Replace a match at a specific line/col/length in content string.
  @spec replace_match(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) ::
          String.t()
  defp replace_match(content, match_line, match_col, match_len, replacement) do
    lines = String.split(content, "\n")

    new_lines =
      List.update_at(lines, match_line, fn line ->
        before = binary_part(line, 0, match_col)

        after_match =
          binary_part(line, match_col + match_len, byte_size(line) - match_col - match_len)

        before <> replacement <> after_match
      end)

    Enum.join(new_lines, "\n")
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
            MingaEditor.Session.State.transition_mode(state.workspace, :command, %CommandState{
              input: "%s/"
            })
      }
    end
  )
end

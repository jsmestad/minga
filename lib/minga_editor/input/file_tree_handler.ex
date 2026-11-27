defmodule MingaEditor.Input.FileTreeHandler do
  @moduledoc """
  Input handler for the file tree scope.

  Handles file tree key bindings (scope trie resolution). Delegates vim
  navigation keys (j/k/gg/G/Ctrl-d) to the mode FSM with the tree
  buffer swapped in as the active buffer.

  Pointer input does not reach this handler. Both semantic frontends send file
  tree clicks as `gui_action` intents with row identity, which
  `MingaEditor.Handlers.GuiActionHandler` applies.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.FileTree.EmptyFolder
  alias MingaEditor.FileTree.Freshness, as: FileTreeFreshness
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Input
  alias Minga.Keymap
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  def handle_key(%{workspace: %{keymap_scope: :file_tree}} = state, cp, mods) do
    state
    |> file_tree_state()
    |> handle_file_tree_scoped_key(state, cp, mods)
  end

  # Not file tree scope
  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @spec handle_file_tree_scoped_key(
          FileTreeState.t(),
          state(),
          non_neg_integer(),
          non_neg_integer()
        ) :: MingaEditor.Input.Handler.result()
  defp handle_file_tree_scoped_key(%FileTreeState{interaction: :help}, state, cp, mods) do
    {:handled, handle_help_key(state, cp, mods)}
  end

  defp handle_file_tree_scoped_key(%FileTreeState{interaction: {:editing, _}}, state, cp, mods) do
    {:handled, handle_inline_edit_key(state, cp, mods)}
  end

  defp handle_file_tree_scoped_key(%FileTreeState{interaction: :filtering}, state, cp, mods) do
    {:handled, handle_filter_key(state, cp, mods)}
  end

  defp handle_file_tree_scoped_key(%FileTreeState{} = file_tree, state, cp, mods) do
    if FileTreeState.focused?(file_tree) do
      handle_file_tree_key(state, cp, mods)
    else
      {:passthrough, state}
    end
  end

  # ── File tree key dispatch ─────────────────────────────────────────────

  @spec handle_file_tree_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp handle_file_tree_key(state, cp, mods) do
    if Minga.Editing.in_leader?(state) do
      {:handled, delegate_leader_to_mode_fsm(state, cp, mods)}
    else
      handle_non_leader_file_tree_key(state, cp, mods)
    end
  end

  @spec handle_non_leader_file_tree_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp handle_non_leader_file_tree_key(state, cp, mods) do
    if Input.key_sequence_pending?(state) do
      {:handled, legacy_delegate_navigation_to_fake_tree_buffer(state, cp, mods)}
    else
      key = {cp, mods}

      vim_state =
        if Minga.Editing.active_model(state) == Minga.Editing.Model.CUA, do: :cua, else: :normal

      case Keymap.resolve_scoped_key(
             :file_tree,
             vim_state,
             key,
             keymap_server: state.interaction.keymap_server
           ) do
        {:command, command} when command in [:move_up, :move_down] ->
          {:handled, move_or_navigate(state, command)}

        {:command, command} ->
          {:handled, Commands.execute(state, command)}

        {:prefix, _node} ->
          {:handled, state}

        :not_found ->
          {:handled, navigate(state, cp, mods)}
      end
    end
  end

  @arrow_up [57_352, 0xF700]
  @arrow_down [57_353, 0xF701]

  # An empty folder has no rows to move through, only its next steps, so j and k (and the arrows) move between those.
  @spec navigate(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp navigate(state, cp, mods) do
    case {FileTreeState.status(file_tree_state(state)), empty_folder_delta(cp, mods)} do
      {:empty, delta} when delta != 0 ->
        update_file_tree(
          state,
          &FileTreeState.move_empty_selection(&1, delta, EmptyFolder.step_count())
        )

      _rows_or_other_key ->
        legacy_delegate_navigation_to_fake_tree_buffer(state, cp, mods)
    end
  end

  # CUA's arrow keys resolve to :move_up and :move_down; in an empty folder they move between its next steps too.
  @spec move_or_navigate(EditorState.t(), :move_up | :move_down) :: EditorState.t()
  defp move_or_navigate(state, command) do
    case FileTreeState.status(file_tree_state(state)) do
      :empty ->
        delta = if command == :move_down, do: 1, else: -1

        update_file_tree(
          state,
          &FileTreeState.move_empty_selection(&1, delta, EmptyFolder.step_count())
        )

      _rows ->
        Commands.execute(state, command)
    end
  end

  @spec empty_folder_delta(non_neg_integer(), non_neg_integer()) :: -1 | 0 | 1
  defp empty_folder_delta(cp, 0) when cp == ?j or cp in @arrow_down, do: 1
  defp empty_folder_delta(cp, 0) when cp == ?k or cp in @arrow_up, do: -1
  defp empty_folder_delta(_cp, _mods), do: 0

  @spec delegate_leader_to_mode_fsm(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp delegate_leader_to_mode_fsm(state, cp, mods) do
    real_active = state.workspace.buffers.active
    state = MingaEditor.do_handle_key(state, cp, mods)

    if state.workspace.buffers.active != real_active do
      state = update_file_tree(state, &FileTreeState.unfocus/1)

      %{
        state
        | workspace: MingaEditor.Session.State.set_keymap_scope(state.workspace, :editor)
      }
    else
      state
    end
  end

  # Legacy BEAM-round-tripped navigation path.
  # This exists for compatibility with Vim motions that have not moved to the semantic frontend-local interaction contract yet. Semantic frontends should own zero-latency local file-tree selection over the last committed row model and send BEAM actions only when the user commits an intent such as open, toggle, rename, delete, or drop. See docs/ARCHITECTURE.md and docs/GUI_PROTOCOL.md.
  @spec legacy_delegate_navigation_to_fake_tree_buffer(
          EditorState.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          EditorState.t()
  defp legacy_delegate_navigation_to_fake_tree_buffer(state, cp, mods) do
    case file_tree_state(state).buffer do
      buf when is_pid(buf) ->
        real_active = state.workspace.buffers.active
        state = set_active_buffer_override(state, buf)
        state = MingaEditor.do_handle_key(state, cp, mods)

        state =
          if Minga.Editing.mode(state) != :normal do
            %{
              state
              | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :normal)
            }
          else
            state
          end

        state =
          if state.workspace.buffers.active == buf do
            set_active_buffer_override(state, real_active)
          else
            state
          end

        case FileTreeState.tree(file_tree_state(state)) do
          nil -> state
          %FileTree{} -> sync_tree_cursor_from_buffer(state, buf)
        end

      _ ->
        state
    end
  end

  @spec sync_tree_cursor_from_buffer(EditorState.t(), pid()) :: EditorState.t()
  defp sync_tree_cursor_from_buffer(state, buf) do
    case FileTreeState.resident_tree(file_tree_state(state)) do
      nil ->
        state

      %FileTree{} = tree ->
        {cursor_line, _col} = Buffer.cursor(buf)

        update_file_tree(
          state,
          &FileTreeState.replace_tree_metadata(&1, FileTree.select(tree, cursor_line))
        )
    end
  end

  # ── Inline editing key handler ──────────────────────────────────────────

  @enter 13
  @escape 27
  @backspace 127
  defguardp special_text_key?(cp)
            when cp in 57_348..57_376 or cp in 0xF700..0xF728

  defguardp printable_text_key?(cp, mods)
            when mods == 0 and cp >= 32 and not special_text_key?(cp)

  @spec handle_inline_edit_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp handle_inline_edit_key(state, @enter, 0) do
    Commands.FileTree.confirm_editing(state)
  end

  defp handle_inline_edit_key(state, @escape, 0) do
    Commands.FileTree.cancel_editing(state)
  end

  defp handle_inline_edit_key(state, @backspace, 0) do
    editing = FileTreeState.editing(file_tree_state(state))

    if editing.text == "" do
      Commands.FileTree.cancel_editing(state)
    else
      # Use String.slice/3 (start, length) to avoid negative index issues.
      new_text = String.slice(editing.text, 0, max(String.length(editing.text) - 1, 0))
      ft = FileTreeState.update_editing_text(file_tree_state(state), new_text)
      set_file_tree(state, ft)
    end
  end

  # Printable characters: append to editing text
  defp handle_inline_edit_key(state, cp, mods) when printable_text_key?(cp, mods) do
    char = <<cp::utf8>>
    editing = FileTreeState.editing(file_tree_state(state))
    new_text = editing.text <> char
    ft = FileTreeState.update_editing_text(file_tree_state(state), new_text)
    set_file_tree(state, ft)
  end

  # All other keys (with modifiers, control chars): swallow them
  defp handle_inline_edit_key(state, _cp, _mods), do: state

  # ── Help and filter key handlers ────────────────────────────────────────

  @spec handle_help_key(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp handle_help_key(state, @escape, 0), do: Commands.FileTree.hide_help(state)
  defp handle_help_key(state, ?/, 0), do: Commands.FileTree.filter(state)
  defp handle_help_key(state, ??, 0), do: Commands.FileTree.toggle_help(state)
  defp handle_help_key(state, _cp, _mods), do: state

  @spec handle_filter_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp handle_filter_key(state, @enter, 0) do
    set_file_tree(state, FileTreeState.accept_filter(file_tree_state(state)))
  end

  defp handle_filter_key(state, @escape, 0), do: Commands.FileTree.clear_filter(state)

  defp handle_filter_key(state, ??, 0), do: Commands.FileTree.toggle_help(state)

  defp handle_filter_key(state, @backspace, 0) do
    text = current_filter_text(state)

    if text == "" do
      Commands.FileTree.clear_filter(state)
    else
      new_text = String.slice(text, 0, max(String.length(text) - 1, 0))
      apply_filter_update(state, new_text)
    end
  end

  defp handle_filter_key(state, cp, mods) when printable_text_key?(cp, mods) do
    new_text = current_filter_text(state) <> <<cp::utf8>>
    apply_filter_update(state, new_text)
  end

  defp handle_filter_key(state, _cp, _mods), do: state

  @spec current_filter_text(EditorState.t()) :: String.t()
  defp current_filter_text(state) do
    case FileTreeState.tree(file_tree_state(state)) do
      %FileTree{filter: filter} when is_binary(filter) -> filter
      _ -> ""
    end
  end

  @spec apply_filter_update(EditorState.t(), String.t()) :: EditorState.t()
  defp apply_filter_update(state, ""), do: Commands.FileTree.reset_filter_query(state)

  defp apply_filter_update(state, filter_text),
    do: FileTreeFreshness.update_filter(state, filter_text)

  # ── Shared helpers ──────────────────────────────────────────────────────

  @spec file_tree_state(EditorState.t()) :: FileTreeState.t()
  defp file_tree_state(state), do: state.workspace.file_tree

  @spec set_active_buffer_override(EditorState.t(), pid() | nil) :: EditorState.t()
  defp set_active_buffer_override(state, pid) do
    %{
      state
      | workspace:
          MingaEditor.Session.State.set_buffers(
            state.workspace,
            (&Buffers.set_active_override(&1, pid)).(state.workspace.buffers)
          )
    }
  end

  @spec set_file_tree(EditorState.t(), FileTreeState.t()) :: EditorState.t()
  defp set_file_tree(state, file_tree) do
    sync_buffer(file_tree)
    %{state | workspace: MingaEditor.Session.State.set_file_tree(state.workspace, file_tree)}
  end

  @spec sync_buffer(FileTreeState.t()) :: :ok
  defp sync_buffer(%FileTreeState{buffer: buffer} = file_tree) when is_pid(buffer) do
    case FileTreeState.tree(file_tree) do
      %FileTree{} = tree -> BufferSync.sync(buffer, tree)
      nil -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp sync_buffer(%FileTreeState{}), do: :ok

  @spec update_file_tree(EditorState.t(), (FileTreeState.t() -> FileTreeState.t())) ::
          EditorState.t()
  defp update_file_tree(state, fun) when is_function(fun, 1) do
    %{
      state
      | workspace:
          MingaEditor.Session.State.set_file_tree(
            state.workspace,
            fun.(state.workspace.file_tree)
          )
    }
  end
end

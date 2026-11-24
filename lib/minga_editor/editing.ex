defmodule MingaEditor.Editing do
  @moduledoc """
  Vim-specific EditorState mutation helpers.

  This module provides read/write access to vim-specific state on
  EditorState (registers, mode_state, recorders, marks). These are
  Editor-domain internals; external callers should use the
  `Minga.Editing` facade for model-agnostic queries like `inserting?`,
  `mode`, `cursor_shape`.

  Model-agnostic queries (inserting?, selecting?, cursor_shape, etc.)
  live on the `Minga.Editing` facade, not here.
  """

  alias MingaEditor.MacroRecorder
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Registers
  alias MingaEditor.VimState
  alias Minga.Mode

  # ── Vim-specific reads ─────────────────────────────────────────────────────

  @doc "Returns the current mode-specific state struct."
  @spec mode_state(EditorState.t() | map()) :: Mode.state()
  def mode_state(%EditorState{workspace: %{editing: vim}}), do: vim.mode_state
  def mode_state(%{workspace: %{editing: vim}}), do: vim.mode_state

  @doc "Returns the visual anchor position from mode_state, or nil."
  @spec visual_anchor(EditorState.t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def visual_anchor(%EditorState{workspace: %{editing: %{mode_state: ms}}})
      when is_map_key(ms, :visual_anchor),
      do: ms.visual_anchor

  def visual_anchor(_state), do: nil

  @doc "Returns the macro recorder struct."
  @spec macro_recorder(EditorState.t()) :: MacroRecorder.t()
  def macro_recorder(%EditorState{workspace: %{editing: vim}}), do: vim.macro_recorder

  @doc "Returns the change recorder struct."
  @spec change_recorder(EditorState.t()) :: MingaEditor.ChangeRecorder.t()
  def change_recorder(%EditorState{workspace: %{editing: vim}}), do: vim.change_recorder

  @doc "Returns `{true, register_name}` when recording, `false` otherwise."
  @spec macro_recording?(EditorState.t()) :: {true, String.t()} | false
  def macro_recording?(state), do: MacroRecorder.recording?(macro_recorder(state))

  @doc "Returns the active register name (empty string for unnamed)."
  @spec active_register(EditorState.t()) :: String.t()
  def active_register(%EditorState{workspace: %{editing: %{reg: reg}}}), do: reg.active

  @doc "Returns the full registers struct."
  @spec registers(EditorState.t()) :: Registers.t()
  def registers(%EditorState{workspace: %{editing: %{reg: reg}}}), do: reg

  # ── Mutation functions ─────────────────────────────────────────────────────

  @spec install_editing(EditorState.t(), VimState.t()) :: EditorState.t()
  defp install_editing(%EditorState{} = state, vim),
    do: %{state | workspace: MingaEditor.Session.State.set_editing(state.workspace, vim)}

  @doc "Sets the active register to `name`."
  @spec set_active_register(EditorState.t(), String.t()) :: EditorState.t()
  def set_active_register(%EditorState{} = state, name) do
    install_editing(
      state,
      MingaEditor.VimState.set_registers(
        state.workspace.editing,
        Registers.set_active(state.workspace.editing.reg, name)
      )
    )
  end

  @doc "Stores `text` in register `name` with the given type."
  @spec put_register(EditorState.t(), String.t(), String.t(), Registers.reg_type()) ::
          EditorState.t()
  def put_register(%EditorState{} = state, name, text, reg_type \\ :charwise) do
    install_editing(
      state,
      MingaEditor.VimState.set_registers(
        state.workspace.editing,
        Registers.put(state.workspace.editing.reg, name, text, reg_type)
      )
    )
  end

  @doc "Resets the active register back to unnamed."
  @spec reset_active_register(EditorState.t()) :: EditorState.t()
  def reset_active_register(%EditorState{} = state) do
    install_editing(
      state,
      MingaEditor.VimState.set_registers(
        state.workspace.editing,
        Registers.reset_active(state.workspace.editing.reg)
      )
    )
  end

  @doc "Sets the leader_node on mode_state."
  @spec set_leader_node(EditorState.t(), term()) :: EditorState.t()
  def set_leader_node(%EditorState{} = state, node) do
    install_editing(
      state,
      MingaEditor.VimState.set_mode_state(
        state.workspace.editing,
        (&%{&1 | leader_node: node}).(state.workspace.editing.mode_state)
      )
    )
  end

  @doc """
  Updates mode_state by applying a function or merging a map.

  When given a function, calls it with the current mode_state and
  replaces mode_state with the result. When given a map, merges it
  into the current mode_state struct.
  """
  @spec update_mode_state(EditorState.t(), (Mode.state() -> Mode.state()) | map()) ::
          EditorState.t()
  def update_mode_state(%EditorState{} = state, fun) when is_function(fun, 1) do
    install_editing(
      state,
      MingaEditor.VimState.set_mode_state(
        state.workspace.editing,
        fun.(state.workspace.editing.mode_state)
      )
    )
  end

  def update_mode_state(%EditorState{} = state, updates) when is_map(updates) do
    install_editing(
      state,
      MingaEditor.VimState.set_mode_state(
        state.workspace.editing,
        (&Map.merge(&1, updates)).(state.workspace.editing.mode_state)
      )
    )
  end

  @doc "Replaces the macro recorder."
  @spec set_macro_recorder(EditorState.t(), MacroRecorder.t()) :: EditorState.t()
  def set_macro_recorder(%EditorState{} = state, rec) do
    install_editing(
      state,
      MingaEditor.VimState.set_macro_recorder(state.workspace.editing, rec)
    )
  end

  @doc "Replaces the change recorder."
  @spec set_change_recorder(EditorState.t(), MingaEditor.ChangeRecorder.t()) :: EditorState.t()
  def set_change_recorder(%EditorState{} = state, rec) do
    install_editing(
      state,
      MingaEditor.VimState.set_change_recorder(state.workspace.editing, rec)
    )
  end

  @doc """
  Records a jump that started at `pos` in the active buffer.

  Sets the `''` position and adds the place to the jump list. Without an active buffer only the `''` position is set.
  """
  @spec save_jump_pos(EditorState.t(), {non_neg_integer(), non_neg_integer()}) ::
          EditorState.t()
  def save_jump_pos(%EditorState{workspace: %{buffers: %{active: buf}}} = state, pos)
      when is_pid(buf) do
    record_jump(state, buf, pos)
  end

  def save_jump_pos(%EditorState{} = state, pos) do
    install_editing(
      state,
      MingaEditor.VimState.set_last_jump_pos(state.workspace.editing, pos)
    )
  end

  @doc """
  Records a jump from the active buffer's cursor, before a location jump moves it.

  A picker preview only shows a location, so nothing is recorded while one runs; the confirmed pick records the jump.
  """
  @spec record_jump_here(EditorState.t()) :: EditorState.t()
  def record_jump_here(%EditorState{buffer_lifecycle: %{buffer_add_context: :preview}} = state),
    do: state

  def record_jump_here(%EditorState{workspace: %{buffers: %{active: buf}}} = state)
      when is_pid(buf),
      do: record_jump(state, buf, Minga.Buffer.cursor(buf))

  def record_jump_here(%EditorState{} = state), do: state

  @doc "Records a jump that started at `pos` in `buffer`, which may not be the active buffer."
  @spec record_jump(EditorState.t(), pid(), {non_neg_integer(), non_neg_integer()}) ::
          EditorState.t()
  def record_jump(%EditorState{} = state, buffer, pos) when is_pid(buffer) do
    install_editing(state, VimState.record_jump(state.workspace.editing, buffer, pos))
  end

  @doc """
  Records leaving `old_buffer` as a jump when the active buffer changed to another buffer.

  Vim counts editing another file as a jump, so `⌃O` returns to the place you left. Nothing is recorded when the active buffer did not change or `old_buffer` is no longer open.
  """
  @spec record_buffer_leave(EditorState.t(), pid() | nil) :: EditorState.t()
  def record_buffer_leave(
        %EditorState{workspace: %{buffers: %{active: active, list: list}}} = state,
        old_buffer
      )
      when is_pid(old_buffer) and old_buffer != active do
    if old_buffer in list,
      do: record_jump(state, old_buffer, Minga.Buffer.cursor(old_buffer)),
      else: state
  catch
    # The buffer can exit before its :DOWN reaches the editor; a missed jump entry is harmless.
    :exit, _ -> state
  end

  def record_buffer_leave(%EditorState{} = state, _old_buffer), do: state

  @doc "Installs the jump list after a walk through it."
  @spec walk_jump_list(EditorState.t(), MingaEditor.JumpList.t()) :: EditorState.t()
  def walk_jump_list(%EditorState{} = state, jump_list) do
    install_editing(
      state,
      VimState.walk_jump_list(state.workspace.editing, jump_list)
    )
  end
end

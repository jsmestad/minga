defmodule Minga.Editor.Editing do
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

  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Registers
  alias Minga.Mode

  # ── Vim-specific reads ─────────────────────────────────────────────────────

  @doc "Returns the current mode-specific state struct."
  @spec mode_state(EditorState.t()) :: Mode.state()
  def mode_state(%EditorState{workspace: %{vim: vim}}), do: vim.mode_state

  @doc "Returns the visual anchor position from mode_state, or nil."
  @spec visual_anchor(EditorState.t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def visual_anchor(%EditorState{workspace: %{vim: %{mode_state: ms}}})
      when is_map_key(ms, :visual_anchor),
      do: ms.visual_anchor

  def visual_anchor(_state), do: nil

  @doc "Returns the macro recorder struct."
  @spec macro_recorder(EditorState.t()) :: MacroRecorder.t()
  def macro_recorder(%EditorState{workspace: %{vim: vim}}), do: vim.macro_recorder

  @doc "Returns the change recorder struct."
  @spec change_recorder(EditorState.t()) :: term()
  def change_recorder(%EditorState{workspace: %{vim: vim}}), do: vim.change_recorder

  @doc "Returns `{true, register_name}` when recording, `false` otherwise."
  @spec macro_recording?(EditorState.t()) :: {true, String.t()} | false
  def macro_recording?(state), do: MacroRecorder.recording?(macro_recorder(state))

  @doc "Returns the active register name (empty string for unnamed)."
  @spec active_register(EditorState.t()) :: String.t()
  def active_register(%EditorState{workspace: %{vim: %{reg: reg}}}), do: reg.active

  @doc "Returns the full registers struct."
  @spec registers(EditorState.t()) :: Registers.t()
  def registers(%EditorState{workspace: %{vim: %{reg: reg}}}), do: reg

  # ── Mutation functions ─────────────────────────────────────────────────────

  @doc "Sets the active register to `name`."
  @spec set_active_register(EditorState.t(), String.t()) :: EditorState.t()
  def set_active_register(%EditorState{} = state, name) do
    put_in(state.workspace.vim.reg.active, name)
  end

  @doc "Stores `text` in register `name` with the given type."
  @spec put_register(EditorState.t(), String.t(), String.t(), Registers.reg_type()) ::
          EditorState.t()
  def put_register(%EditorState{} = state, name, text, reg_type \\ :charwise) do
    put_in(state.workspace.vim.reg, Registers.put(state.workspace.vim.reg, name, text, reg_type))
  end

  @doc "Resets the active register back to unnamed."
  @spec reset_active_register(EditorState.t()) :: EditorState.t()
  def reset_active_register(%EditorState{} = state) do
    put_in(state.workspace.vim.reg, Registers.reset_active(state.workspace.vim.reg))
  end

  @doc "Sets the leader_node on mode_state."
  @spec set_leader_node(EditorState.t(), term()) :: EditorState.t()
  def set_leader_node(%EditorState{} = state, node) do
    put_in(state.workspace.vim.mode_state.leader_node, node)
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
    new_ms = fun.(state.workspace.vim.mode_state)
    put_in(state.workspace.vim.mode_state, new_ms)
  end

  def update_mode_state(%EditorState{} = state, updates) when is_map(updates) do
    new_ms = Map.merge(state.workspace.vim.mode_state, updates)
    put_in(state.workspace.vim.mode_state, new_ms)
  end

  @doc "Replaces the macro recorder."
  @spec set_macro_recorder(EditorState.t(), MacroRecorder.t()) :: EditorState.t()
  def set_macro_recorder(%EditorState{} = state, rec) do
    put_in(state.workspace.vim.macro_recorder, rec)
  end

  @doc "Replaces the change recorder."
  @spec set_change_recorder(EditorState.t(), term()) :: EditorState.t()
  def set_change_recorder(%EditorState{} = state, rec) do
    put_in(state.workspace.vim.change_recorder, rec)
  end

  @doc "Saves the jump position when the cursor crosses a line boundary."
  @spec save_jump_pos(EditorState.t(), {non_neg_integer(), non_neg_integer()}) ::
          EditorState.t()
  def save_jump_pos(%EditorState{} = state, pos) do
    put_in(state.workspace.vim.last_jump_pos, pos)
  end
end

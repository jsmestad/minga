defmodule Minga.Editor.Editing do
  @moduledoc """
  Facade over the active editing model's state.

  All call sites that need to query or update the editing model's state
  (mode, mode_state, registers, recorders) go through this module instead
  of reaching into `state.vim.*` directly. Today the only implementation
  is Vim; when CUA arrives (#306, Phase D), this module will dispatch to
  the active editing model based on a config flag.

  ## Why this exists

  71 call sites across 25 files access `state.vim.mode`, `state.vim.mode_state`,
  `state.vim.reg`, `state.vim.macro_recorder`, and `state.vim.change_recorder`
  directly. That couples every consumer to the Vim struct layout. This facade
  provides a stable API so consumers don't need to know which editing model
  is active or how its state is structured.

  ## Categories

  **Query functions** read editing model state without mutations:
  `mode/1`, `mode_state/1`, `inserting?/1`, `minibuffer_mode?/1`,
  `in_leader?/1`, `cursor_shape/1`, `visual_anchor/1`.

  **Mutation functions** update editing model state and return EditorState:
  `set_active_register/2`, `put_register/3`, `reset_active_register/1`,
  `set_leader_node/2`, `update_mode_state/2`, `set_macro_recorder/2`,
  `set_change_recorder/2`.

  **Compound accessors** read deep into sub-structs:
  `macro_recorder/1`, `change_recorder/1`, `active_register/1`,
  `macro_recording?/1`.
  """

  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Registers
  alias Minga.Mode

  # ── Query functions ──────────────────────────────────────────────────────

  @doc "Returns the current editing mode atom (e.g. :normal, :insert, :visual)."
  @spec mode(EditorState.t()) :: Mode.mode()
  def mode(%EditorState{vim: vim}), do: vim.mode

  @doc "Returns the current mode-specific state struct."
  @spec mode_state(EditorState.t()) :: Mode.state()
  def mode_state(%EditorState{vim: vim}), do: vim.mode_state

  @doc "Returns true when the editing model is in insert mode."
  @spec inserting?(EditorState.t()) :: boolean()
  def inserting?(%EditorState{vim: vim}), do: vim.mode == :insert

  @doc "Returns true when the editing model is in a visual selection mode."
  @spec selecting?(EditorState.t()) :: boolean()
  def selecting?(%EditorState{vim: vim}),
    do: vim.mode in [:visual, :visual_line, :visual_block]

  @doc "Returns true when in a minibuffer-occupying mode (command, search, eval, search_prompt)."
  @spec minibuffer_mode?(EditorState.t()) :: boolean()
  def minibuffer_mode?(%EditorState{vim: vim}),
    do: vim.mode in [:command, :search, :eval, :search_prompt]

  @doc "Returns true when a leader key sequence is pending (leader_node is a map)."
  @spec in_leader?(EditorState.t()) :: boolean()
  def in_leader?(%EditorState{vim: %{mode_state: ms}}) when is_map_key(ms, :leader_node),
    do: is_map(ms.leader_node)

  def in_leader?(_state), do: false

  @doc "Returns the cursor shape for the current editing mode."
  @spec cursor_shape(EditorState.t()) :: :beam | :block | :underline
  def cursor_shape(state) do
    if inserting?(state), do: :beam, else: :block
  end

  @doc "Returns the visual anchor position from mode_state, or nil."
  @spec visual_anchor(EditorState.t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def visual_anchor(%EditorState{vim: %{mode_state: ms}})
      when is_map_key(ms, :visual_anchor),
      do: ms.visual_anchor

  def visual_anchor(_state), do: nil

  # ── Compound accessors ────────────────────────────────────────────────────

  @doc "Returns the macro recorder struct."
  @spec macro_recorder(EditorState.t()) :: MacroRecorder.t()
  def macro_recorder(%EditorState{vim: vim}), do: vim.macro_recorder

  @doc "Returns the change recorder struct."
  @spec change_recorder(EditorState.t()) :: term()
  def change_recorder(%EditorState{vim: vim}), do: vim.change_recorder

  @doc "Returns `{true, register_name}` when recording, `false` otherwise."
  @spec macro_recording?(EditorState.t()) :: {true, String.t()} | false
  def macro_recording?(state), do: MacroRecorder.recording?(macro_recorder(state))

  @doc """
  Returns the macro recording status for display.

  Returns `{true, register_name}` when recording, `false` otherwise.
  Matches the shape expected by status bar data structs.
  """
  @spec macro_recording_status(EditorState.t()) :: {true, String.t()} | false
  def macro_recording_status(state), do: MacroRecorder.recording?(macro_recorder(state))

  @doc "Returns the active register name (empty string for unnamed)."
  @spec active_register(EditorState.t()) :: String.t()
  def active_register(%EditorState{vim: %{reg: reg}}), do: reg.active

  @doc "Returns the full registers struct."
  @spec registers(EditorState.t()) :: Registers.t()
  def registers(%EditorState{vim: %{reg: reg}}), do: reg

  # ── Mutation functions ─────────────────────────────────────────────────────

  @doc "Sets the active register to `name`."
  @spec set_active_register(EditorState.t(), String.t()) :: EditorState.t()
  def set_active_register(%EditorState{} = state, name) do
    put_in(state.vim.reg.active, name)
  end

  @doc "Stores `text` in register `name` with the given type."
  @spec put_register(EditorState.t(), String.t(), String.t(), Registers.reg_type()) ::
          EditorState.t()
  def put_register(%EditorState{} = state, name, text, reg_type \\ :charwise) do
    %{state | vim: %{state.vim | reg: Registers.put(state.vim.reg, name, text, reg_type)}}
  end

  @doc "Resets the active register back to unnamed."
  @spec reset_active_register(EditorState.t()) :: EditorState.t()
  def reset_active_register(%EditorState{} = state) do
    %{state | vim: %{state.vim | reg: Registers.reset_active(state.vim.reg)}}
  end

  @doc "Sets the leader_node on mode_state."
  @spec set_leader_node(EditorState.t(), term()) :: EditorState.t()
  def set_leader_node(%EditorState{} = state, node) do
    put_in(state.vim.mode_state.leader_node, node)
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
    new_ms = fun.(state.vim.mode_state)
    %{state | vim: %{state.vim | mode_state: new_ms}}
  end

  def update_mode_state(%EditorState{} = state, updates) when is_map(updates) do
    new_ms = Map.merge(state.vim.mode_state, updates)
    %{state | vim: %{state.vim | mode_state: new_ms}}
  end

  @doc "Replaces the macro recorder."
  @spec set_macro_recorder(EditorState.t(), MacroRecorder.t()) :: EditorState.t()
  def set_macro_recorder(%EditorState{} = state, rec) do
    %{state | vim: %{state.vim | macro_recorder: rec}}
  end

  @doc "Replaces the change recorder."
  @spec set_change_recorder(EditorState.t(), term()) :: EditorState.t()
  def set_change_recorder(%EditorState{} = state, rec) do
    %{state | vim: %{state.vim | change_recorder: rec}}
  end

  @doc "Saves the jump position when the cursor crosses a line boundary."
  @spec save_jump_pos(EditorState.t(), {non_neg_integer(), non_neg_integer()}) ::
          EditorState.t()
  def save_jump_pos(%EditorState{} = state, pos) do
    %{state | vim: %{state.vim | last_jump_pos: pos}}
  end
end

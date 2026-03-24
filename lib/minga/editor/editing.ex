defmodule Minga.Editor.Editing do
  @moduledoc """
  Facade over the active editing model's state.

  All call sites that need to query or update the editing model's state
  (mode, mode_state, registers, recorders) go through this module instead
  of reaching into `state.vim.*` directly.

  Query functions that have `EditingModel` behaviour callbacks dispatch
  through the active model. This means `inserting?/1`, `selecting?/1`,
  `cursor_shape/1`, `key_sequence_pending?/1`, and `status_segment/1`
  all call the appropriate `EditingModel.Vim` callback today, and will
  dispatch to `EditingModel.CUA` when CUA arrives (#306, Phase D).

  The active editing model is determined by the `:editing_model` config
  option (`:vim` by default). The model module is resolved once and
  cached; query functions construct a lightweight model state struct to
  call through the behaviour.

  ## Categories

  **Model-dispatched queries** go through `EditingModel` callbacks:
  `inserting?/1`, `selecting?/1`, `cursor_shape/1`,
  `key_sequence_pending?/1`, `status_segment/1`.

  **Direct queries** read from the vim state directly (these will become
  model-dispatched as CUA grows its own equivalents):
  `mode/1`, `mode_state/1`, `minibuffer_mode?/1`, `in_leader?/1`,
  `visual_anchor/1`.

  **Mutation functions** update editing model state and return EditorState:
  `set_active_register/2`, `put_register/3`, `reset_active_register/1`,
  `set_leader_node/2`, `update_mode_state/2`, `set_macro_recorder/2`,
  `set_change_recorder/2`.

  **Compound accessors** read deep into sub-structs:
  `macro_recorder/1`, `change_recorder/1`, `active_register/1`,
  `macro_recording?/1`.
  """

  alias Minga.EditingModel
  alias Minga.EditingModel.CUA, as: CUAModel
  alias Minga.EditingModel.Vim, as: VimModel
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Registers
  alias Minga.Mode

  # ── Model resolution ─────────────────────────────────────────────────────

  @doc """
  Returns the active editing model module.

  Reads the `:editing_model` config option and returns the corresponding
  module. Falls back to `EditingModel.Vim` if the config is unavailable
  (e.g., during test setup before Config is started).
  """
  @spec active_model() :: module()
  def active_model do
    case Minga.Config.Options.get(:editing_model) do
      :vim -> VimModel
      :cua -> CUAModel
    end
  catch
    # Config.Options may not be started yet (test setup, app boot).
    :exit, _ -> VimModel
  end

  # Builds a lightweight EditingModel state struct from EditorState
  # for dispatching through behaviour callbacks.
  @spec model_state(EditorState.t()) :: EditingModel.state()
  defp model_state(%EditorState{} = state) do
    case active_model() do
      VimModel -> VimModel.from_editor(state.vim.mode, state.vim.mode_state)
      CUAModel -> CUAModel.from_editor()
    end
  end

  # ── Model-dispatched queries ─────────────────────────────────────────────

  @doc "Returns true when the editing model is in an inserting state."
  @spec inserting?(EditorState.t()) :: boolean()
  def inserting?(%EditorState{} = state) do
    active_model().inserting?(model_state(state))
  end

  @doc "Returns true when the editing model has an active selection."
  @spec selecting?(EditorState.t()) :: boolean()
  def selecting?(%EditorState{} = state) do
    active_model().selecting?(model_state(state))
  end

  @doc "Returns the cursor shape for the current editing state."
  @spec cursor_shape(EditorState.t()) :: :beam | :block | :underline
  def cursor_shape(%EditorState{} = state) do
    active_model().cursor_shape(model_state(state))
  end

  @doc "Returns true when a multi-key sequence is in progress."
  @spec key_sequence_pending?(EditorState.t()) :: boolean()
  def key_sequence_pending?(%EditorState{} = state) do
    active_model().key_sequence_pending?(model_state(state))
  end

  @doc "Returns a short string for the status bar mode segment."
  @spec status_segment(EditorState.t()) :: String.t()
  def status_segment(%EditorState{} = state) do
    active_model().status_segment(model_state(state))
  end

  # ── Direct queries (not yet model-dispatched) ────────────────────────────

  @doc "Returns the current editing mode atom (e.g. :normal, :insert, :visual)."
  @spec mode(EditorState.t()) :: Mode.mode()
  def mode(%EditorState{vim: vim}), do: vim.mode

  @doc "Returns the current mode-specific state struct."
  @spec mode_state(EditorState.t()) :: Mode.state()
  def mode_state(%EditorState{vim: vim}), do: vim.mode_state

  @doc "Returns true when in a minibuffer-occupying mode (command, search, eval, search_prompt)."
  @spec minibuffer_mode?(EditorState.t()) :: boolean()
  def minibuffer_mode?(%EditorState{vim: vim}),
    do: vim.mode in [:command, :search, :eval, :search_prompt]

  @doc "Returns true when a leader key sequence is pending (leader_node is a map)."
  @spec in_leader?(EditorState.t()) :: boolean()
  def in_leader?(%EditorState{vim: %{mode_state: ms}}) when is_map_key(ms, :leader_node),
    do: is_map(ms.leader_node)

  def in_leader?(_state), do: false

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

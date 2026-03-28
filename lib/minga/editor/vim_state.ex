defmodule Minga.Editor.VimState do
  @moduledoc """
  Vim-specific editing model state.

  Groups the modal FSM state, registers, marks, and recording state
  that are specific to vim-style editing. This substruct on EditorState
  creates the swap boundary for alternative editing models (CUA, #306):
  replace `state.workspace.editing` with a different struct to change the editing model.

  ## Fields

  * `mode` — current vim mode (:normal, :insert, :visual, etc.)
  * `mode_state` — mode-specific state (pending operator, search input, etc.)
  * `reg` — named registers and active register selection
  * `marks` — buffer-local marks (outer key is buffer pid, inner is mark name)
  * `last_jump_pos` — cursor position before the last jump
  * `last_find_char` — last f/F/t/T char for `;` and `,` repeat
  * `change_recorder` — tracks changes for dot repeat
  * `macro_recorder` — tracks macro recording state
  """

  alias Minga.Buffer
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State.Registers
  alias Minga.Mode

  @typedoc "Stored last find-char motion for ; and , repeat."
  @type last_find_char :: {Minga.Mode.State.find_direction(), String.t()} | nil

  @typedoc "Buffer-local marks: outer key is buffer pid, inner key is mark name."
  @type marks :: %{pid() => %{String.t() => Buffer.position()}}

  @type t :: %__MODULE__{
          mode: Mode.mode(),
          mode_state: Mode.state(),
          reg: Registers.t(),
          marks: marks(),
          last_jump_pos: Buffer.position() | nil,
          last_find_char: last_find_char(),
          change_recorder: ChangeRecorder.t(),
          macro_recorder: MacroRecorder.t()
        }

  @enforce_keys [:mode, :mode_state]
  defstruct mode: :normal,
            mode_state: nil,
            reg: %Registers{},
            marks: %{},
            last_jump_pos: nil,
            last_find_char: nil,
            change_recorder: ChangeRecorder.new(),
            macro_recorder: MacroRecorder.new()

  @doc "Returns a new VimState with default values."
  @spec new() :: t()
  def new do
    %__MODULE__{
      mode: :normal,
      mode_state: Mode.initial_state()
    }
  end

  @doc """
  Transitions to a new mode, returning an updated VimState.

  This is the single gate function for all mode changes. Every mode
  transition in the codebase must go through this function (or the
  `EditorState.transition_mode/3` convenience wrapper). A custom Credo
  check enforces this by flagging raw `mode:` writes on the vim struct.

  When `mode_state` is nil, sensible defaults are used:
  - `:normal`, `:insert` → `Mode.initial_state()`
  - `:command` → `%CommandState{}`
  - `:eval` → `%EvalState{}`
  - `:replace` → `%ReplaceState{}`

  Modes that require context (`:visual`, `:search`, `:search_prompt`,
  `:substitute_confirm`, `:extension_confirm`, `:operator_pending`)
  must be given an explicit `mode_state`.
  """
  @spec transition(t(), Mode.mode(), Mode.state() | nil) :: t()
  def transition(%__MODULE__{} = vim, mode, mode_state \\ nil) do
    ms = mode_state || default_mode_state(mode)
    %{vim | mode: mode, mode_state: ms}
  end

  @spec default_mode_state(Mode.mode()) :: Mode.state()
  defp default_mode_state(:normal), do: Mode.initial_state()
  defp default_mode_state(:insert), do: Mode.initial_state()
  defp default_mode_state(:command), do: %Minga.Mode.CommandState{}
  defp default_mode_state(:eval), do: %Minga.Mode.EvalState{}
  defp default_mode_state(:replace), do: %Minga.Mode.ReplaceState{}

  defp default_mode_state(mode) do
    raise ArgumentError,
          "Mode #{inspect(mode)} requires an explicit mode_state argument. " <>
            "Call VimState.transition(vim, #{inspect(mode)}, mode_state) instead."
  end

  # ── Field mutation functions (Rule 2 enforcement) ──────────────────────

  @doc "Updates mode_state without changing the mode."
  @spec set_mode_state(t(), Mode.state()) :: t()
  def set_mode_state(%__MODULE__{} = vim, mode_state) do
    %{vim | mode_state: mode_state}
  end

  @doc "Sets the marks map for a specific buffer."
  @spec set_buffer_marks(t(), pid(), %{String.t() => Buffer.position()}) :: t()
  def set_buffer_marks(%__MODULE__{marks: marks} = vim, buf_pid, buf_marks) do
    %{vim | marks: Map.put(marks, buf_pid, buf_marks)}
  end

  @doc "Replaces the entire marks map."
  @spec set_marks(t(), marks()) :: t()
  def set_marks(%__MODULE__{} = vim, marks) do
    %{vim | marks: marks}
  end

  @doc "Records the cursor position before a jump."
  @spec set_last_jump_pos(t(), Buffer.position() | nil) :: t()
  def set_last_jump_pos(%__MODULE__{} = vim, pos) do
    %{vim | last_jump_pos: pos}
  end

  @doc "Records the last f/F/t/T char for ; and , repeat."
  @spec set_last_find_char(t(), last_find_char()) :: t()
  def set_last_find_char(%__MODULE__{} = vim, find_char) do
    %{vim | last_find_char: find_char}
  end

  @doc "Updates the macro recorder state."
  @spec set_macro_recorder(t(), MacroRecorder.t()) :: t()
  def set_macro_recorder(%__MODULE__{} = vim, recorder) do
    %{vim | macro_recorder: recorder}
  end

  @doc "Updates the change recorder state."
  @spec set_change_recorder(t(), ChangeRecorder.t()) :: t()
  def set_change_recorder(%__MODULE__{} = vim, recorder) do
    %{vim | change_recorder: recorder}
  end

  @doc "Updates the register state."
  @spec set_registers(t(), Registers.t()) :: t()
  def set_registers(%__MODULE__{} = vim, reg) do
    %{vim | reg: reg}
  end
end

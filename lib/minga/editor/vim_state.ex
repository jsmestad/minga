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

  alias Minga.Buffer.Document
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State.Registers
  alias Minga.Mode

  @typedoc "Stored last find-char motion for ; and , repeat."
  @type last_find_char :: {Minga.Mode.State.find_direction(), String.t()} | nil

  @typedoc "Buffer-local marks: outer key is buffer pid, inner key is mark name."
  @type marks :: %{pid() => %{String.t() => Document.position()}}

  @type t :: %__MODULE__{
          mode: Mode.mode(),
          mode_state: Mode.state(),
          reg: Registers.t(),
          marks: marks(),
          last_jump_pos: Document.position() | nil,
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
end

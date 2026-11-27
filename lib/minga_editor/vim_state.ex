defmodule MingaEditor.VimState do
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
  * `jump_list`: the places jumps started from, across buffers (`⌃O` / `⌃I`)
  * `last_find_char` — last f/F/t/T char for `;` and `,` repeat
  * `change_recorder` — tracks changes for dot repeat
  * `macro_recorder` — tracks macro recording state
  """

  alias Minga.Buffer
  alias MingaEditor.ChangeRecorder
  alias MingaEditor.JumpList
  alias MingaEditor.MacroRecorder
  alias MingaEditor.State.Registers
  alias MingaEditor.VimState.PendingKeep
  alias Minga.Mode

  @typedoc "Stored last find-char motion for ; and , repeat."
  @type last_find_char :: {Minga.Mode.State.find_direction(), String.t()} | nil

  @typedoc "Buffer-local marks: outer key is buffer pid, inner key is mark name."
  @type marks :: %{pid() => %{String.t() => Buffer.position()}}

  @typep keep_state :: PendingKeep.t() | {:ready, pid(), :queue.queue(PendingKeep.input())}

  @type t :: %__MODULE__{
          mode: Mode.mode(),
          mode_state: Mode.state(),
          reg: Registers.t(),
          marks: marks(),
          last_jump_pos: Buffer.position() | nil,
          jump_list: JumpList.t(),
          last_find_char: last_find_char(),
          desired_col: non_neg_integer() | nil,
          change_recorder: ChangeRecorder.t(),
          macro_recorder: MacroRecorder.t(),
          pending_keep: keep_state() | nil
        }

  @enforce_keys [:mode, :mode_state]
  defstruct mode: :normal,
            mode_state: nil,
            reg: %Registers{},
            marks: %{},
            last_jump_pos: nil,
            jump_list: %JumpList{},
            last_find_char: nil,
            desired_col: nil,
            change_recorder: ChangeRecorder.new(),
            macro_recorder: MacroRecorder.new(),
            pending_keep: nil

  @doc "Returns a new VimState with default values."
  @spec new() :: t()
  def new do
    %__MODULE__{
      mode: :normal,
      mode_state: Mode.initial_state()
    }
  end

  @doc """
  Returns a vim state whose `mode_state` matches `mode`.

  The Mode FSM carries the leaving mode's state through `Mode.apply_result/2`
  so commands that fire on `:execute_then_transition` can read the leaving
  state (e.g. `:yank_visual_selection` reads `%VisualState{}` to find the
  selection range). During that window `workspace.editing.mode_state` is
  the leaving struct while `mode` is already the new mode.

  Code paths that snapshot the workspace into long-lived storage (tab
  contexts, session save) must not capture that in-flight pair, because
  restoring it would put `:normal` next to a `%CommandState{}` (or similar)
  and break the next leader keypress with a `KeyError`. Call this before
  snapshotting.

  Pass-through if `mode_state` is already the right struct for `mode`.
  Otherwise rebuild via `transition/3` with `nil` to use the default for
  default-state modes; raises for context-required modes (which should
  never be a snapshot's resting state).
  """
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{mode: mode, mode_state: mode_state} = vim) do
    if is_struct(mode_state, expected_struct(mode)) do
      vim
    else
      transition(vim, mode, nil)
    end
  end

  @spec expected_struct(Mode.mode()) :: module()
  defp expected_struct(:normal), do: Minga.Mode.State
  defp expected_struct(:insert), do: Minga.Mode.State
  defp expected_struct(:command), do: Minga.Mode.CommandState
  defp expected_struct(:eval), do: Minga.Mode.EvalState
  defp expected_struct(:replace), do: Minga.Mode.ReplaceState
  defp expected_struct(:visual), do: Minga.Mode.VisualState
  defp expected_struct(:operator_pending), do: Minga.Mode.OperatorPendingState
  defp expected_struct(:search), do: Minga.Mode.SearchState
  defp expected_struct(:search_prompt), do: Minga.Mode.SearchPromptState
  defp expected_struct(:substitute_confirm), do: Minga.Mode.SubstituteConfirmState
  defp expected_struct(:extension_confirm), do: Minga.Mode.ExtensionConfirmState
  defp expected_struct(:tool_confirm), do: Minga.Mode.ToolConfirmState
  defp expected_struct(:delete_confirm), do: Minga.Mode.DeleteConfirmState

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

  @doc """
  Records a jump that started at `pos` in `buffer`.

  Sets the `''` position and adds the place to the jump list that `⌃O` walks back through.
  """
  @spec record_jump(t(), pid(), Buffer.position()) :: t()
  def record_jump(%__MODULE__{jump_list: jump_list} = vim, buffer, pos) when is_pid(buffer) do
    %{vim | last_jump_pos: pos, jump_list: JumpList.record(jump_list, buffer, pos)}
  end

  @doc "Installs the jump list after a walk through it (`⌃O`, `⌃I`, or a pick from `SPC s j`)."
  @spec walk_jump_list(t(), JumpList.t()) :: t()
  def walk_jump_list(%__MODULE__{} = vim, %JumpList{} = jump_list) do
    %{vim | jump_list: jump_list}
  end

  @doc "Records the last f/F/t/T char for ; and , repeat."
  @spec set_last_find_char(t(), last_find_char()) :: t()
  def set_last_find_char(%__MODULE__{} = vim, find_char) do
    %{vim | last_find_char: find_char}
  end

  @doc "Sets the desired screen column for vertical movement (Vim's curswant)."
  @spec set_desired_col(t(), non_neg_integer() | nil) :: t()
  def set_desired_col(%__MODULE__{} = vim, col) do
    %{vim | desired_col: col}
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

  @doc "Registers a pending Keep beside the originating Vim repeat recorder."
  @spec begin_keep(t(), reference(), pid(), pos_integer(), PendingKeep.continuation()) :: t()
  def begin_keep(%__MODULE__{pending_keep: nil} = vim, id, buffer, count, continuation) do
    keep = PendingKeep.new(id, buffer, count, continuation, vim.change_recorder)

    %{vim | pending_keep: keep}
  end

  @doc "Keeps independent input moving and holds dependent keys in the originating buffer."
  @spec hold_keep_key(t(), pid() | nil, ChangeRecorder.key()) :: {:held, t()} | :independent
  def hold_keep_key(
        %__MODULE__{pending_keep: %PendingKeep{buffer: buffer} = keep} = vim,
        buffer,
        key
      ) do
    case PendingKeep.hold(keep, key, vim.mode) do
      {:held, keep} -> {:held, %{vim | pending_keep: keep}}
      :independent -> :independent
    end
  end

  def hold_keep_key(%__MODULE__{}, _buffer, _key), do: :independent

  @doc "Holds dependent commands already resolved by their input owner."
  @spec hold_keep_command(t(), pid() | nil, Mode.command()) :: {:held, t()} | :independent
  def hold_keep_command(
        %__MODULE__{pending_keep: %PendingKeep{buffer: buffer} = keep} = vim,
        buffer,
        command
      ),
      do: {:held, %{vim | pending_keep: PendingKeep.enqueue(keep, {:command, buffer, command})}}

  def hold_keep_command(%__MODULE__{}, _buffer, _command), do: :independent

  @doc "Starts a different editing context without the previous context's Keep input."
  @spec clear_keep(t()) :: t()
  def clear_keep(%__MODULE__{} = vim), do: %{vim | pending_keep: nil}

  @doc "Drops unfinished input for a retired exact buffer."
  @spec retire_keep(t(), pid()) :: t()
  def retire_keep(%__MODULE__{pending_keep: %PendingKeep{buffer: pid}} = vim, pid),
    do: clear_keep(vim)

  def retire_keep(%__MODULE__{pending_keep: {:ready, pid, _}} = vim, pid), do: clear_keep(vim)
  def retire_keep(%__MODULE__{} = vim, _pid), do: vim

  @doc "Applies only the identified Keep result and makes held input ready to replay."
  @spec finish_keep(
          t(),
          reference(),
          :ok | :refused | :gone,
          {pid() | nil, Buffer.position() | nil}
        ) :: {:ok, PendingKeep.t(), t()} | :stale
  def finish_keep(
        %__MODULE__{pending_keep: %PendingKeep{id: id} = keep} = vim,
        id,
        outcome,
        {active, cursor}
      ) do
    vim =
      if outcome == :ok do
        same_mode? =
          keep.buffer == active and keep.continuation == {:visual, vim.mode_state, cursor}

        same_recorder? =
          keep.repeat_revision == vim.change_recorder.revision and
            not ChangeRecorder.recording?(vim.change_recorder)

        settle_review(vim, :keep, keep.count, keep.continuation, same_mode?, same_recorder?)
      else
        vim
      end

    pending =
      if outcome != :gone and not :queue.is_empty(keep.input),
        do: {:ready, keep.buffer, keep.input}

    {:ok, keep, %{vim | pending_keep: pending}}
  end

  def finish_keep(%__MODULE__{}, _id, _success?, _active), do: :stale

  @doc "Takes ready input only when its original buffer owns the editing context again."
  @spec take_keep_input(t(), pid() | nil) :: {:ok, [PendingKeep.input()], t()} | :none
  def take_keep_input(%__MODULE__{pending_keep: {:ready, buffer, input}} = vim, buffer),
    do: {:ok, :queue.to_list(input), clear_keep(vim)}

  def take_keep_input(%__MODULE__{}, _buffer), do: :none

  @doc "Records an already-published review command and exits its original Visual selection."
  @spec complete_review(
          t(),
          :keep | :reject,
          pos_integer(),
          PendingKeep.continuation(),
          boolean()
        ) ::
          t()
  def complete_review(%__MODULE__{} = vim, decision, count, continuation, end_visual?),
    do: settle_review(vim, decision, count, continuation, end_visual?, true)

  @spec settle_review(
          t(),
          :keep | :reject,
          pos_integer(),
          PendingKeep.continuation(),
          boolean(),
          boolean()
        ) ::
          t()
  defp settle_review(vim, decision, count, continuation, end_visual?, record?) do
    vim = if end_visual?, do: transition(vim, :normal), else: vim

    repeat_count =
      case continuation do
        {:visual, _, _} -> count
        {:normal, requested} -> requested || count
        _notice_only -> nil
      end

    if is_integer(repeat_count) and record? and not ChangeRecorder.replaying?(vim.change_recorder) do
      recorder = ChangeRecorder.record_review(vim.change_recorder, decision, repeat_count)
      set_change_recorder(vim, recorder)
    else
      vim
    end
  end

  @doc "Updates the register state."
  @spec set_registers(t(), Registers.t()) :: t()
  def set_registers(%__MODULE__{} = vim, reg) do
    %{vim | reg: reg}
  end
end

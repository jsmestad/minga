defmodule MingaEditor.Input.CUA.Dispatch do
  @moduledoc """
  Input handler for CUA editing mode.

  This replaces `Input.ModeFSM` at the bottom of the surface handler
  stack when the editing model is `:cua`. It processes keys through
  `EditingModel.CUA.process_key/2` and dispatches the resulting
  commands through `MingaEditor.Commands.execute/2`.

  Unlike the vim `ModeFSM` path, CUA dispatch doesn't need:
  - Mode transitions (CUA has no modes)
  - Change recording for dot-repeat (CUA doesn't have dot-repeat)
  - Macro recording (CUA doesn't have macros)
  - Read-only guard for mode transitions (CUA never transitions)

  It does need:
  - Command execution through the same Commands module
  - Break undo coalescing on Enter
  - Post-key housekeeping (reparse, render, completion)
  """

  @behaviour MingaEditor.Input.Handler

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.Mouse
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, modifiers) do
    key = {codepoint, modifiers}
    cua_state = Minga.Editing.Model.CUA.from_editor()

    {_mode, commands, _new_cua_state} =
      Minga.Editing.Model.CUA.process_key(cua_state, key)

    # Break undo coalescing on Enter so each line is a separate undo step
    if codepoint == 0x0D and state.workspace.buffers.active do
      Buffer.break_undo_coalescing(state.workspace.buffers.active)
    end

    state =
      Enum.reduce(commands, state, fn cmd, acc ->
        case Commands.execute(acc, cmd) do
          {s2, {:whichkey_update, wk}} -> EditorState.set_whichkey(s2, wk)
          s2 when is_map(s2) -> s2
          {s2, _action} -> s2
        end
      end)

    {:handled, state}
  end

  @impl true
  @spec handle_mouse(
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()
  def handle_mouse(state, row, col, button, mods, event_type, click_count) do
    new_state = Mouse.handle(state, row, col, button, mods, event_type, click_count)
    {:handled, new_state}
  end
end

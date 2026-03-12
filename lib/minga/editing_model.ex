defmodule Minga.EditingModel do
  @moduledoc """
  Behaviour for pluggable editing strategies.

  An editing model translates key sequences into command atoms. Vim
  implements it today with the Mode FSM; CUA (#306) will provide an
  alternative with permanent insert mode, Shift+arrow selection, and
  Ctrl chord bindings.

  ## Why this exists

  Without this abstraction, the vim Mode FSM is wired directly into
  `KeyDispatch` and `ModeFSM`. There's no boundary between "the editing
  model" and "the editor." CUA needs the same entry points (handle a
  key, produce commands) without duplicating the dispatch machinery.
  The behaviour formalizes the contract so vim and CUA are peers, not
  special cases.

  ## How it connects to NavigableContent

  The editing model produces command atoms (`:move_down`, `:delete_line`,
  `{:insert_char, "x"}`). The command executor interprets these against
  a `NavigableContent` implementation. The editing model doesn't know
  what content type it's operating on; the NavigableContent adapter
  handles the translation.

  ```
  Key → EditingModel.process_key → command atoms
  Command atoms → Commands.execute → NavigableContent operations
  ```

  ## State ownership

  Each editing model owns its own state struct. Vim state includes mode,
  mode_state, count prefix, leader sequence, pending operators. CUA state
  would include selection anchor, clipboard mode, etc. The editor stores
  the editing model's state opaquely; it never pattern-matches on the
  internals.

  Currently vim state (`mode`, `mode_state`) lives on `EditorState` for
  backward compatibility. It will move into `EditingModel.Vim.State` as
  part of the Phase H migration. This behaviour is designed to support
  both the current layout and the target layout.
  """

  @typedoc """
  A command produced by the editing model. Either a bare atom
  (e.g. `:move_left`) or a tagged tuple with arguments
  (e.g. `{:insert_char, \"x\"}`).
  """
  @type command ::
          atom()
          | {atom(), term()}
          | {atom(), term(), term()}
          | {atom(), term(), term(), term()}

  @typedoc "A key event: `{codepoint, modifiers}`."
  @type key :: {non_neg_integer(), non_neg_integer()}

  @typedoc """
  A mode label for the status line and guards. Examples: `:normal`,
  `:insert`, `:visual`, `:command`.
  """
  @type mode_label :: atom()

  @typedoc "Opaque editing model state. Each implementation defines its own struct."
  @type state :: term()

  @doc """
  Processes a key event through the editing model.

  Returns `{mode_label, commands, new_state}` where:
  - `mode_label` is the mode after processing (e.g. `:normal`, `:insert`)
  - `commands` is a list of command atoms to execute (may be empty)
  - `new_state` is the updated editing model state

  Count prefixes (e.g. `3j`) are handled internally by the editing model.
  The returned command list is already expanded (three `:move_down` atoms,
  not one with a count argument).
  """
  @callback process_key(state(), key()) :: {mode_label(), [command()], state()}

  @doc "Returns a fresh initial state for this editing model."
  @callback initial_state() :: state()

  @doc """
  Returns the display string for the status line.

  Examples: `"-- NORMAL --"`, `"-- INSERT --"`, `":wq"` (command mode
  shows the accumulated input).
  """
  @callback mode_display(state()) :: String.t()

  @doc """
  Returns the current mode as an atom.

  Used by guards and branches that need to know the mode without
  parsing the display string. Examples: `:normal`, `:insert`, `:visual`.
  """
  @callback mode(state()) :: mode_label()
end

defmodule Minga.Mode.SubstituteConfirm do
  @moduledoc """
  Substitute confirm mode (`:%s/old/new/gc`).

  Steps through each match and lets the user decide whether to replace it.

  ## Key bindings

  | Key       | Action                                    |
  |-----------|-------------------------------------------|
  | `y`       | Accept current match, advance to next     |
  | `n`       | Skip current match, advance to next       |
  | `a`       | Accept all remaining matches, finish      |
  | `q`       | Stop, keep decisions made so far          |
  | `Escape`  | Same as `q`                               |
  """

  @behaviour Minga.Mode

  alias Minga.Mode
  alias Minga.Mode.SubstituteConfirmState

  @escape 27

  @impl Mode
  @spec handle_key(Mode.key(), SubstituteConfirmState.t()) :: Mode.result()

  # y → accept current, advance
  def handle_key({?y, _mods}, %SubstituteConfirmState{} = state) do
    new_accepted = [state.current | state.accepted]
    advance(%{state | accepted: new_accepted})
  end

  # n → skip current, advance
  def handle_key({?n, _mods}, %SubstituteConfirmState{} = state) do
    advance(state)
  end

  # a → accept all remaining, finish
  def handle_key({?a, _mods}, %SubstituteConfirmState{} = state) do
    remaining = Enum.to_list(state.current..(length(state.matches) - 1)//1)
    new_accepted = remaining ++ state.accepted

    {:execute_then_transition, [:apply_substitute_confirm], :normal,
     %{state | accepted: new_accepted}}
  end

  # q or Escape → finish with current decisions
  def handle_key({cp, _mods}, %SubstituteConfirmState{} = state)
      when cp == ?q or cp == @escape do
    {:execute_then_transition, [:apply_substitute_confirm], :normal, state}
  end

  # Ignore all other keys
  def handle_key(_key, %SubstituteConfirmState{} = state) do
    {:continue, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec advance(SubstituteConfirmState.t()) :: Mode.result()
  defp advance(%SubstituteConfirmState{current: current, matches: matches} = state) do
    next = current + 1

    if next >= length(matches) do
      # Last match — finish
      {:execute_then_transition, [:apply_substitute_confirm], :normal, state}
    else
      {:execute, :substitute_confirm_advance, %{state | current: next}}
    end
  end
end

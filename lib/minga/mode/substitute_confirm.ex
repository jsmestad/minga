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

  import Bitwise

  alias Minga.Mode
  alias Minga.Mode.SubstituteConfirmState

  @escape 27

  # An answer is a letter pressed without Control, Alt or Command. A chord is not an answer: without enhanced key
  # reporting a terminal sends Esc followed by a letter as Alt and that letter when both arrive together.
  @chord_mods 0x0E

  @impl Mode
  @spec handle_key(Mode.key(), SubstituteConfirmState.t()) :: Mode.result()

  # y → accept current, advance
  def handle_key({?y, mods}, %SubstituteConfirmState{} = state)
      when band(mods, @chord_mods) == 0 do
    state |> SubstituteConfirmState.accept() |> advance_or_finish()
  end

  # n → skip current, advance
  def handle_key({?n, mods}, %SubstituteConfirmState{} = state)
      when band(mods, @chord_mods) == 0 do
    state |> SubstituteConfirmState.skip() |> advance_or_finish()
  end

  # a → accept all remaining, finish
  def handle_key({?a, mods}, %SubstituteConfirmState{} = state)
      when band(mods, @chord_mods) == 0 do
    state |> SubstituteConfirmState.accept_remaining() |> finish()
  end

  # q or Escape → finish with current decisions
  def handle_key({cp, mods}, %SubstituteConfirmState{} = state)
      when cp == @escape or (cp == ?q and band(mods, @chord_mods) == 0) do
    finish(state)
  end

  # Ignore all other keys
  def handle_key(_key, %SubstituteConfirmState{} = state) do
    {:continue, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec advance_or_finish(SubstituteConfirmState.t()) :: Mode.result()
  defp advance_or_finish(state) do
    case SubstituteConfirmState.current_match(state) do
      nil -> finish(state)
      _match -> {:execute, :substitute_confirm_advance, state}
    end
  end

  @spec finish(SubstituteConfirmState.t()) :: Mode.result()
  defp finish(state), do: {:execute_then_transition, [:apply_substitute_confirm], :normal, state}
end

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
    state |> SubstituteConfirmState.accept() |> advance_or_finish()
  end

  # n → skip current, advance
  def handle_key({?n, _mods}, %SubstituteConfirmState{} = state) do
    state |> SubstituteConfirmState.skip() |> advance_or_finish()
  end

  # a → accept all remaining, finish
  def handle_key({?a, _mods}, %SubstituteConfirmState{} = state) do
    state |> SubstituteConfirmState.accept_remaining() |> finish()
  end

  # q or Escape → finish with current decisions
  def handle_key({cp, _mods}, %SubstituteConfirmState{} = state)
      when cp == ?q or cp == @escape do
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

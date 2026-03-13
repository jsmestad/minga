defmodule Minga.Mode.ExtensionConfirm do
  @moduledoc """
  Extension update confirmation mode.

  Steps through each pending extension update and lets the user decide
  whether to apply it.

  ## Key bindings

  | Key       | Action                                    |
  |-----------|-------------------------------------------|
  | `Y`       | Accept current update, advance to next    |
  | `n`       | Skip current update, advance to next      |
  | `d`       | Show details (git log) for current update |
  | `q`       | Stop, apply accepted updates so far       |
  | `Escape`  | Same as `q`                               |
  """

  @behaviour Minga.Mode

  alias Minga.Mode
  alias Minga.Mode.ExtensionConfirmState

  @escape 27

  @impl Mode
  @spec handle_key(Mode.key(), ExtensionConfirmState.t()) :: Mode.result()

  # Y → accept current update, advance
  def handle_key({?Y, _mods}, %ExtensionConfirmState{} = state) do
    new_accepted = [state.current | state.accepted]
    advance(%{state | accepted: new_accepted, show_details: false})
  end

  # n → skip current, advance
  def handle_key({?n, _mods}, %ExtensionConfirmState{} = state) do
    advance(%{state | show_details: false})
  end

  # d → toggle details for current update
  def handle_key({?d, _mods}, %ExtensionConfirmState{} = state) do
    {:execute, :extension_confirm_details, %{state | show_details: !state.show_details}}
  end

  # q or Escape → finish with current decisions
  def handle_key({cp, _mods}, %ExtensionConfirmState{} = state)
      when cp == ?q or cp == @escape do
    {:execute_then_transition, [:apply_extension_updates], :normal,
     %{state | show_details: false}}
  end

  # Ignore all other keys
  def handle_key(_key, %ExtensionConfirmState{} = state) do
    {:continue, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec advance(ExtensionConfirmState.t()) :: Mode.result()
  defp advance(%ExtensionConfirmState{current: current, updates: updates} = state) do
    next = current + 1

    if next >= length(updates) do
      # Last update — finish and apply accepted
      {:execute_then_transition, [:apply_extension_updates], :normal, state}
    else
      {:continue, %{state | current: next}}
    end
  end
end

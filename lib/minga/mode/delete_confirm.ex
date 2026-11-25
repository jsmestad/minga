defmodule Minga.Mode.DeleteConfirm do
  @moduledoc """
  File tree delete confirmation mode.

  Prompts the user to confirm deletion of a file or directory.
  Two phases: first tries trash, if trash fails offers permanent delete.

  ## Key bindings

  | Key       | Action                         |
  |-----------|--------------------------------|
  | `y`       | Confirm: delete the entry      |
  | `n`       | Cancel: return to file tree    |
  | `Escape`  | Cancel: return to file tree    |
  """

  @behaviour Minga.Mode

  import Bitwise

  alias Minga.Mode
  alias Minga.Mode.DeleteConfirmState

  @escape 27

  # An answer is a letter pressed without Control, Alt or Command. A chord is not an answer: without enhanced key
  # reporting a terminal sends Esc followed by a letter as Alt and that letter when both arrive together.
  @chord_mods 0x0E

  @impl Mode
  @spec handle_key(Mode.key(), DeleteConfirmState.t()) :: Mode.result()

  # y → confirm deletion (trash or permanent depending on phase)
  def handle_key({?y, mods}, %DeleteConfirmState{phase: :trash} = state)
      when band(mods, @chord_mods) == 0 do
    {:execute_then_transition, [{:delete_confirm_trash, state.path}], :normal, state}
  end

  def handle_key({?y, mods}, %DeleteConfirmState{phase: :permanent} = state)
      when band(mods, @chord_mods) == 0 do
    {:execute_then_transition, [{:delete_confirm_permanent, state.path}], :normal, state}
  end

  # n → cancel
  def handle_key({?n, mods}, %DeleteConfirmState{} = state) when band(mods, @chord_mods) == 0 do
    {:execute_then_transition, [:delete_confirm_cancel], :normal, state}
  end

  # Escape → cancel
  def handle_key({@escape, _mods}, %DeleteConfirmState{} = state) do
    {:execute_then_transition, [:delete_confirm_cancel], :normal, state}
  end

  # Ignore other keys
  def handle_key(_key, %DeleteConfirmState{} = state) do
    {:continue, state}
  end
end

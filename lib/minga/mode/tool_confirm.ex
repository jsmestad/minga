defmodule Minga.Mode.ToolConfirm do
  @moduledoc """
  Tool install confirmation mode.

  Prompts the user to install a missing tool (LSP server or formatter).
  Steps through each pending tool sequentially.

  ## Key bindings

  | Key       | Action                                    |
  |-----------|-------------------------------------------|
  | `y`       | Accept: install the tool, advance to next |
  | `n`       | Decline: skip this tool, advance to next  |
  | `Escape`  | Dismiss all remaining prompts             |
  """

  @behaviour Minga.Mode

  alias Minga.Mode
  alias Minga.Mode.ToolConfirmState

  @escape 27

  @impl Mode
  @spec handle_key(Mode.key(), ToolConfirmState.t()) :: Mode.result()

  # y → install current tool, advance or finish
  def handle_key({?y, _mods}, %ToolConfirmState{} = state) do
    name = Enum.at(state.pending, state.current)
    advance_or_finish([{:tool_confirm_accept, name}], state)
  end

  # n → decline current tool, advance or finish
  def handle_key({?n, _mods}, %ToolConfirmState{} = state) do
    name = Enum.at(state.pending, state.current)
    declined = MapSet.put(state.declined, name)
    advance_or_finish([{:tool_confirm_decline, name}], %{state | declined: declined})
  end

  # Escape → dismiss all remaining
  def handle_key({@escape, _mods}, %ToolConfirmState{} = state) do
    remaining =
      state.pending
      |> Enum.drop(state.current)
      |> Enum.reduce(state.declined, &MapSet.put(&2, &1))

    {:execute_then_transition, [{:tool_confirm_dismiss, remaining}], :normal, state}
  end

  # Ignore other keys
  def handle_key(_key, %ToolConfirmState{} = state) do
    {:continue, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec advance_or_finish([Mode.command()], ToolConfirmState.t()) :: Mode.result()
  defp advance_or_finish(commands, %ToolConfirmState{current: current, pending: pending} = state) do
    next = current + 1

    if next >= length(pending) do
      {:execute_then_transition, commands, :normal, state}
    else
      {:execute, commands, %{state | current: next}}
    end
  end
end

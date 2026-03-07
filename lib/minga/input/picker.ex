defmodule Minga.Input.Picker do
  @moduledoc """
  Input handler for the fuzzy picker overlay.

  When a picker is active, all keys route to the picker UI. Commands
  returned by the picker (e.g., open file, switch buffer) are dispatched
  through the editor's command system.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.PickerUI

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{picker_ui: %{picker: picker}} = state, codepoint, modifiers)
      when is_struct(picker, Minga.Picker) do
    new_state =
      case PickerUI.handle_key(state, codepoint, modifiers) do
        {s, {:execute_command, cmd}} -> Minga.Editor.dispatch_command(s, cmd)
        s -> s
      end

    {:handled, new_state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end

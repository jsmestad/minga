defmodule Minga.Test.InputMouseOnlyHandler do
  @moduledoc false

  @behaviour MingaEditor.Input.Handler

  @impl true
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _click_count) do
    {:passthrough, state}
  end
end

defmodule Minga.Test.InputLaterKeyHandler do
  @moduledoc false

  @behaviour MingaEditor.Input.Handler

  @impl true
  def handle_key(state, ?x, 0), do: {:handled, Map.put(state, :later_key_handler, :consumed)}
  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}
end

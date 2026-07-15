defmodule MingaEditor.Test.ExtensionEventHandlerTwo do
  @moduledoc false

  @behaviour MingaEditor.Extension.EventHandler

  alias MingaEditor.State, as: EditorState

  @impl true
  @spec handle_editor_event(EditorState.t(), MingaEditor.Extension.EventHandler.event()) ::
          MingaEditor.Extension.EventHandler.callback_result()
  def handle_editor_event(state, event) do
    send(self(), {:extension_handler_called, __MODULE__, event})

    callback =
      Process.get({__MODULE__, :callback}, fn current_state, _event ->
        {:handled, current_state}
      end)

    callback.(state, event)
  end
end

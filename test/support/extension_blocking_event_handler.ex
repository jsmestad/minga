defmodule MingaEditor.Test.ExtensionBlockingEventHandler do
  @moduledoc false

  @behaviour MingaEditor.Extension.EventHandler

  alias MingaEditor.State, as: EditorState

  @impl true
  @spec handle_editor_event(EditorState.t(), MingaEditor.Extension.EventHandler.event()) ::
          MingaEditor.Extension.EventHandler.callback_result()
  def handle_editor_event(state, {:editor_action, :block, {test_pid, token}}) do
    send(test_pid, {:extension_callback_entered, token, self()})

    receive do
      {:release_extension_callback, ^token} -> {:handled, state}
    end
  end

  def handle_editor_event(_state, {:source_unload, _source}), do: exit(:unload_failed)
  def handle_editor_event(_state, _event), do: :not_matched
end

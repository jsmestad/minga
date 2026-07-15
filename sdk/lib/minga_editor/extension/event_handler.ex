defmodule MingaEditor.Extension.EventHandler do
  @moduledoc """
  Contract for synchronous runtime editor events declared by an extension.

  Returning `:not_matched` means the callback ran successfully and declined an
  editor action. Callback failures are reported by the host runtime and are not
  represented by this successful callback return type.
  """

  @typedoc "Runtime editor events available to SDK consumers."
  @type event ::
          {:buffer_saved, pid()}
          | {:editor_action, atom(), term()}
          | {:source_unload, {:extension, atom()}}

  @typedoc "Runtime editor event categories available in the public DSL."
  @type event_kind :: :buffer_saved | :editor_action | :source_unload

  @typedoc "A successful state transition or explicit decline."
  @type callback_result :: {:handled, state :: term()} | :not_matched

  @doc "Handles one runtime editor event synchronously."
  @callback handle_editor_event(state :: term(), event()) :: callback_result()
end

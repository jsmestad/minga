defmodule MingaEditor.Extension.EventHandler do
  @moduledoc """
  Contract for synchronous extension callbacks that transform editor state.

  `:buffer_saved` callbacks fan out, `:editor_action` callbacks are first-match,
  and `:source_unload` callbacks run only for the source being finalized.
  Returning `:not_matched` means the callback ran successfully and declined.
  """

  alias Minga.Extension.CallbackInvoker
  alias MingaEditor.State, as: EditorState

  @typedoc "A runtime editor event offered to registered extensions."
  @type event ::
          {:buffer_saved, pid()}
          | {:editor_action, atom(), term()}
          | {:source_unload, CallbackInvoker.source()}

  @typedoc "Runtime event categories used to index registered handlers."
  @type event_kind :: :buffer_saved | :editor_action | :source_unload

  @typedoc "A handler either updates editor state or successfully declines."
  @type callback_result :: {:handled, EditorState.t()} | :not_matched

  @typedoc "Ordinary dispatch result, including explicit extension failure."
  @type result ::
          callback_result()
          | {:callback_failed, CallbackInvoker.failure()}
          | {:callback_failed, [CallbackInvoker.failure()], EditorState.t()}

  @doc "Handles one runtime editor event synchronously in the Editor process."
  @callback handle_editor_event(EditorState.t(), event()) :: callback_result()
end

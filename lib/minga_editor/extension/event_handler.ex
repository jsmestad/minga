defmodule MingaEditor.Extension.EventHandler do
  @moduledoc """
  Contract for worker-executed extension callbacks that transform an editor snapshot.

  `:buffer_saved` callbacks fan out, `:editor_action` callbacks are first-match,
  and `:source_unload` callbacks run only for the source being finalized.
  Returning `:not_matched` means the callback ran successfully and declined.
  The callback process identity is opaque, and a returned snapshot commits only
  when it has not been superseded by newer Editor state.
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

  @doc "Handles one runtime editor event in a bounded effect worker."
  @callback handle_editor_event(EditorState.t(), event()) :: callback_result()
end

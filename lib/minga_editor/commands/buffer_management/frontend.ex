defmodule MingaEditor.Commands.BufferManagement.Frontend do
  @moduledoc """
  Behaviour for GUI/TUI variant dispatch of buffer management commands.

  Commands that show messages or warnings use the bottom panel on GUI
  and gap buffers in popup windows on TUI.
  """

  alias MingaEditor.State, as: EditorState

  @callback view_messages(EditorState.t()) :: EditorState.t()
  @callback view_warnings(EditorState.t()) :: EditorState.t()
end

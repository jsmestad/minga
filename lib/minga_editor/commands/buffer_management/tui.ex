defmodule MingaEditor.Commands.BufferManagement.TUI do
  @moduledoc "TUI variant of buffer management commands. Opens gap buffers in windows."

  @behaviour MingaEditor.Commands.BufferManagement.Frontend

  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec view_messages(EditorState.t()) :: EditorState.t()
  def view_messages(state) do
    case Minga.Log.MessagesBuffer.pid() do
      nil -> EditorState.set_status(state, "No messages buffer")
      pid -> BufferManagement.open_special_buffer(state, "*Messages*", pid)
    end
  end

  @impl true
  @spec view_warnings(EditorState.t()) :: EditorState.t()
  def view_warnings(state) do
    case Minga.Log.MessagesBuffer.pid() do
      nil -> EditorState.set_status(state, "No messages buffer")
      pid -> BufferManagement.open_special_buffer(state, "*Messages*", pid)
    end
  end
end

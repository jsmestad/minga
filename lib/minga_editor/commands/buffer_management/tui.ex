defmodule MingaEditor.Commands.BufferManagement.TUI do
  @moduledoc "TUI variant of buffer management commands. Opens gap buffers in windows."

  @behaviour MingaEditor.Commands.BufferManagement.Frontend

  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec view_messages(EditorState.t()) :: EditorState.t()
  def view_messages(%{workspace: %{buffers: %{messages: nil}}} = state) do
    EditorState.set_status(state, "No messages buffer")
  end

  def view_messages(%{workspace: %{buffers: %{messages: msg_buf}}} = state) do
    BufferManagement.open_special_buffer(state, "*Messages*", msg_buf)
  end

  @impl true
  @spec view_warnings(EditorState.t()) :: EditorState.t()
  def view_warnings(%{workspace: %{buffers: %{messages: nil}}} = state) do
    EditorState.set_status(state, "No messages buffer")
  end

  def view_warnings(%{workspace: %{buffers: %{messages: msg_buf}}} = state) do
    # Warnings appear in *Messages* with [WARN] prefix (no separate buffer)
    BufferManagement.open_special_buffer(state, "*Messages*", msg_buf)
  end
end

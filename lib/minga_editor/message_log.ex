defmodule MingaEditor.MessageLog do
  @moduledoc """
  GUI MessageStore helpers for the editor's `:log_message` event subscription.

  All logging flows through `Minga.Log`, which broadcasts `:log_message` events.
  `Minga.Log.MessagesBuffer` handles the gap buffer (TUI). This module handles
  the structured `MessageStore` (GUI) via `append_to_store/3`, called by the
  editor's `EventDispatcher` when it receives a `:log_message` broadcast.
  """

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Panel.MessageStore

  @doc """
  Appends an entry to the structured MessageStore without writing to the
  shared `*Messages*` buffer.

  Used by the editor's `:log_message` subscription so external broadcasts
  (LSP, parser, git, agent) still surface in the GUI Messages tab. The
  shared buffer is updated by `Minga.Log.MessagesBuffer` directly from the
  same broadcast, so we deliberately do not append twice here.
  """
  @spec append_to_store(EditorState.t(), String.t(), MessageStore.level()) ::
          EditorState.t()
  def append_to_store(state, text, level_override) do
    {parsed_level, subsystem, _clean_text} = MessageStore.parse_prefix(text)
    level = level_override || parsed_level

    %{state | message_store: MessageStore.append(state.message_store, text, level, subsystem)}
  end

  @doc """
  Returns the appropriate log prefix for the frontend type.
  """
  @spec frontend_prefix(EditorState.t()) :: String.t()
  def frontend_prefix(%{capabilities: %{frontend_type: :native_gui}}), do: "GUI"
  def frontend_prefix(_state), do: "ZIG"
end

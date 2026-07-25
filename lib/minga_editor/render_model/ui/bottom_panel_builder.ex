defmodule MingaEditor.RenderModel.UI.BottomPanelBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.BottomPanel
  alias MingaEditor.BottomPanel, as: EditorPanel
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  @doc """
  Builds the bottom panel model.

  Returns `{model, updated_message_store}` because resolving the messages tab
  advances the message_store cursor when new entries have arrived. The caller
  must apply the updated message_store back to ctx.
  """
  @spec build(Context.t()) :: {BottomPanel.t(), MessageStore.t()}
  def build(%Context{
        intent: %{frame: %{shell_state: %TraditionalState{} = shell_state}},
        message_store: %MessageStore{} = store
      }) do
    build_panel(TraditionalState.bottom_panel(shell_state), store)
  end

  def build(%Context{message_store: %MessageStore{} = store}) do
    {%BottomPanel{visible?: false}, store}
  end

  @spec build_panel(EditorPanel.t() | map(), term()) :: {BottomPanel.t(), term()}
  defp build_panel(%{visible: false}, store) do
    {%BottomPanel{visible?: false}, store}
  end

  defp build_panel(%{visible: true} = panel, %MessageStore{} = store) do
    store = MessageStore.ensure_stream_instance(store)

    base = %BottomPanel{
      visible?: true,
      active_tab_index: 0,
      height_percent: panel.height_percent,
      filter_byte: EditorPanel.filter_byte(panel.filter),
      stream_instance: message_stream_instance(store),
      tabs: [{0x01, "Messages"}]
    }

    resolve_content(base, store)
  end

  @spec message_stream_instance(MessageStore.t()) :: MessageStore.stream_instance()
  defp message_stream_instance(%MessageStore{stream_instance: stream_instance}),
    do: stream_instance

  @spec resolve_content(BottomPanel.t(), MessageStore.t()) :: {BottomPanel.t(), MessageStore.t()}
  defp resolve_content(base, store) do
    new_entries = MessageStore.entries_since(store, store.last_sent_id)
    messages = Enum.map(new_entries, &to_message_entry/1)

    last_id = if new_entries == [], do: store.last_sent_id, else: Enum.at(new_entries, -1).id

    {%{base | messages: messages}, MessageStore.mark_sent(store, last_id)}
  end

  @spec to_message_entry(MessageStore.Entry.t()) :: BottomPanel.MessageEntry.t()
  defp to_message_entry(entry) do
    {ts_secs, _micro} =
      entry.timestamp |> NaiveDateTime.to_time() |> Time.to_seconds_after_midnight()

    %BottomPanel.MessageEntry{
      id: entry.id,
      level_byte: MessageStore.level_byte(entry.level),
      subsystem_byte: MessageStore.subsystem_byte(entry.subsystem),
      ts_secs: ts_secs,
      file_path: entry.file_path,
      text: entry.text
    }
  end
end

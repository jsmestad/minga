defmodule MingaEditor.RenderModel.UI.BottomPanelBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.BottomPanel
  alias MingaEditor.BottomPanel, as: EditorPanel
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.UI.Panel.MessageStore

  @doc """
  Builds the bottom panel model.

  Returns `{model, updated_message_store}` because resolving the messages tab
  advances the message_store cursor when new entries have arrived. The caller
  must apply the updated message_store back to ctx.
  """
  @spec build(Context.t()) :: {BottomPanel.t(), term()}
  def build(%{shell_state: %{bottom_panel: panel}, message_store: store}) do
    build_panel(panel, store)
  end

  def build(%{message_store: store}) do
    {%BottomPanel{visible?: false}, store}
  end

  def build(_ctx) do
    {%BottomPanel{visible?: false}, nil}
  end

  @spec build_panel(EditorPanel.t() | map(), term()) :: {BottomPanel.t(), term()}
  defp build_panel(%{visible: false}, store) do
    {%BottomPanel{visible?: false}, store}
  end

  defp build_panel(%{visible: true} = panel, store) do
    active_index = Enum.find_index(panel.tabs, &(&1 == panel.active_tab)) || 0

    tabs =
      Enum.map(panel.tabs, fn tab ->
        {EditorPanel.tab_type_byte(tab), EditorPanel.tab_name(tab)}
      end)

    base = %BottomPanel{
      visible?: true,
      active_tab_index: active_index,
      height_percent: panel.height_percent,
      filter_byte: EditorPanel.filter_byte(panel.filter),
      tabs: tabs
    }

    resolve_content(panel.active_tab, base, store)
  end

  @spec resolve_content(atom(), BottomPanel.t(), term()) :: {BottomPanel.t(), term()}
  defp resolve_content(:messages, base, store) do
    new_entries = MessageStore.entries_since(store, store.last_sent_id)
    messages = Enum.map(new_entries, &to_message_entry/1)

    last_id = if new_entries == [], do: store.last_sent_id, else: List.last(new_entries).id

    {%{base | messages: messages}, MessageStore.mark_sent(store, last_id)}
  end

  defp resolve_content(_other_tab, base, store) do
    {base, store}
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

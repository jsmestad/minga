defmodule MingaEditor.RenderModel.UI.BottomPanelBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.BottomPanel, as: EditorPanel
  alias MingaEditor.RenderModel.UI.BottomPanelBuilder
  alias MingaEditor.UI.Panel.MessageStore
  alias Minga.RenderModel.UI.BottomPanel

  defp ctx(panel, store), do: %{shell_state: %{bottom_panel: panel}, message_store: store}

  describe "build/1" do
    test "returns a hidden model and untouched store for a hidden panel" do
      store = %MessageStore{}
      {model, out_store} = BottomPanelBuilder.build(ctx(%EditorPanel{visible: false}, store))

      assert %BottomPanel{visible?: false} = model
      assert out_store == store
    end

    test "returns a hidden model when ctx has no shell panel" do
      store = %MessageStore{}
      {model, out_store} = BottomPanelBuilder.build(%{message_store: store})

      assert %BottomPanel{visible?: false} = model
      assert out_store == store
    end

    test "resolves tabs, active index, height, and filter for a visible panel" do
      panel = %EditorPanel{
        visible: true,
        active_tab: :diagnostics,
        tabs: [:messages, :diagnostics, :terminal],
        height_percent: 45,
        filter: :warnings
      }

      {model, _store} = BottomPanelBuilder.build(ctx(panel, %MessageStore{}))

      assert model.visible?
      assert model.active_tab_index == 1
      assert model.height_percent == 45
      assert model.filter_byte == 0x01
      assert model.tabs == [{0x01, "Messages"}, {0x02, "Diagnostics"}, {0x03, "Terminal"}]
    end

    test "non-messages tab carries no message entries and leaves the store untouched" do
      store =
        %MessageStore{}
        |> MessageStore.append("hi", :info, :editor)

      panel = %EditorPanel{visible: true, active_tab: :diagnostics, tabs: [:diagnostics]}
      {model, out_store} = BottomPanelBuilder.build(ctx(panel, store))

      assert model.messages == []
      assert out_store == store
    end

    test "messages tab resolves new entries and advances the store cursor" do
      store =
        %MessageStore{}
        |> MessageStore.append("Editor started", :info, :editor)
        |> MessageStore.append("[LSP] connected", :info, :lsp)

      panel = %EditorPanel{visible: true, active_tab: :messages, tabs: [:messages]}
      {model, out_store} = BottomPanelBuilder.build(ctx(panel, store))

      assert length(model.messages) == 2
      assert out_store.last_sent_id == 2

      first = hd(model.messages)
      assert first.id == 1
      assert first.level_byte == 1
      assert first.subsystem_byte == 0
      assert first.text == "Editor started"
    end

    test "sends only incremental entries after a prior send" do
      store = %MessageStore{} |> MessageStore.append("First", :info, :editor)
      panel = %EditorPanel{visible: true, active_tab: :messages, tabs: [:messages]}

      {model1, store2} = BottomPanelBuilder.build(ctx(panel, store))
      assert length(model1.messages) == 1
      assert store2.last_sent_id == 1

      store3 = MessageStore.append(store2, "Second", :warning, :lsp)
      {model2, store4} = BottomPanelBuilder.build(ctx(panel, store3))

      assert length(model2.messages) == 1
      assert hd(model2.messages).text == "Second"
      assert store4.last_sent_id == 2
    end
  end
end

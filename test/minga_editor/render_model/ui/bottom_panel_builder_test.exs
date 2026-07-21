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

    test "projects a visible panel as the Messages tab with height and filter" do
      panel = %EditorPanel{visible: true, height_percent: 45, filter: :warnings}

      {model, _store} = BottomPanelBuilder.build(ctx(panel, %MessageStore{}))

      assert model.visible?
      assert model.active_tab_index == 0
      assert model.height_percent == 45
      assert model.filter_byte == 0x01
      assert model.tabs == [{0x01, "Messages"}]
    end

    test "messages tab resolves new entries and advances the store cursor" do
      store =
        %MessageStore{}
        |> MessageStore.append("Editor started", :info, :editor)
        |> MessageStore.append("[LSP] connected", :info, :lsp)

      panel = %EditorPanel{visible: true}
      {model, out_store} = BottomPanelBuilder.build(ctx(panel, store))

      assert model.stream_instance == store.stream_instance
      assert Enum.count(model.messages) == 2
      assert out_store.last_sent_id == 2

      first = hd(model.messages)
      assert first.id == 1
      assert first.level_byte == 1
      assert first.subsystem_byte == 0
      assert first.text == "Editor started"
    end

    test "sends only incremental entries after a prior send" do
      store = %MessageStore{} |> MessageStore.append("First", :info, :editor)
      panel = %EditorPanel{visible: true}

      {model1, store2} = BottomPanelBuilder.build(ctx(panel, store))
      assert Enum.count(model1.messages) == 1
      assert store2.last_sent_id == 1

      store3 = MessageStore.append(store2, "Second", :warning, :lsp)
      {model2, store4} = BottomPanelBuilder.build(ctx(panel, store3))

      assert Enum.count(model2.messages) == 1
      assert hd(model2.messages).text == "Second"
      assert store4.last_sent_id == 2
    end

    test "fresh producers can reuse ids without reusing stream identity" do
      first_store = MessageStore.new() |> MessageStore.append("First", :info, :editor)
      second_store = MessageStore.new() |> MessageStore.append("Second", :info, :editor)
      panel = %EditorPanel{visible: true}

      {first_model, _first_store} = BottomPanelBuilder.build(ctx(panel, first_store))
      {second_model, _second_store} = BottomPanelBuilder.build(ctx(panel, second_store))

      assert hd(first_model.messages).id == 1
      assert hd(second_model.messages).id == 1
      assert first_model.stream_instance != second_model.stream_instance
    end
  end
end

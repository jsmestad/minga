defmodule MingaEditor.UI.Picker.SourceTest do
  @moduledoc "Tests for Picker.Source helper functions and optional callback fallbacks."

  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.ProjectSource
  alias MingaEditor.UI.Picker.Source

  defmodule NoActionsSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "No actions"

    @impl true
    def candidates(_ctx), do: [{:a, "item", "desc"}]

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state
  end

  defmodule WithPreviewSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "With preview"

    @impl true
    def candidates(_ctx), do: [{:a, "item", "desc"}]

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state

    @impl true
    def preview(_item, %{theme: %{fg: fg}}), do: [[{"preview", fg, false}]]
  end

  defmodule LivePreviewOnlySource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "Live preview only"

    @impl true
    def candidates(_ctx), do: [{:a, "item", "desc"}]

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state

    @impl true
    def preview?, do: true
  end

  defmodule WithGuiPreviewSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "With GUI preview"

    @impl true
    def candidates(_ctx), do: [{:a, "item", "desc"}]

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state

    @impl true
    def gui_preview?, do: true
  end

  defmodule WithActionsSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "With actions"

    @impl true
    def candidates(_ctx), do: [{:a, "item", "desc"}]

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state

    @impl true
    def actions(_item), do: [{"Open", :open}, {"Delete", :delete}]

    @impl true
    def on_action(:open, _item, state), do: Map.put(state, :opened, true)
    def on_action(:delete, _item, state), do: Map.put(state, :deleted, true)
    def on_action(_action, _item, state), do: state
  end

  defmodule WithBulkSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "With bulk"

    @impl true
    def candidates(_ctx), do: [{:a, "item", "desc"}]

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state

    @impl true
    def on_bulk_select(items, state), do: Map.put(state, :bulk_selected, items)

    @impl true
    def bulk_actions(_items), do: [{"Apply all", :apply_all}]

    @impl true
    def on_bulk_action(:apply_all, items, state), do: Map.put(state, :bulk_action_items, items)
    def on_bulk_action(_action, _items, state), do: state
  end

  describe "has_actions?/1" do
    test "returns false for source without actions callback" do
      refute Source.has_actions?(NoActionsSource)
    end

    test "returns true for source with actions and on_action callbacks" do
      assert Source.has_actions?(WithActionsSource)
    end
  end

  describe "actions/2" do
    test "returns empty list for source without actions callback" do
      assert Source.actions(NoActionsSource, {:a, "item", "desc"}) == []
    end

    test "returns actions list for source with actions callback" do
      actions = Source.actions(WithActionsSource, {:a, "item", "desc"})
      assert actions == [{"Open", :open}, {"Delete", :delete}]
    end
  end

  describe "bulk select helpers" do
    test "bulk_select returns unchanged state for source without bulk callback" do
      assert Source.bulk_select(NoActionsSource, [:a], %{untouched: true}) == %{untouched: true}
    end

    test "bulk_select delegates to source with bulk callback" do
      assert Source.bulk_select(WithBulkSource, [:a, :b], %{}) == %{bulk_selected: [:a, :b]}
    end
  end

  describe "bulk action helpers" do
    test "bulk_actions returns empty list for source without bulk callbacks" do
      assert Source.bulk_actions(NoActionsSource, [:a]) == []
    end

    test "bulk_actions delegates to source with bulk callbacks" do
      assert Source.bulk_actions(WithBulkSource, [:a]) == [{"Apply all", :apply_all}]
    end

    test "on_bulk_action returns unchanged state for source without bulk callbacks" do
      assert Source.on_bulk_action(NoActionsSource, :apply_all, [:a], %{untouched: true}) == %{
               untouched: true
             }
    end

    test "on_bulk_action delegates to source with bulk callbacks" do
      assert Source.on_bulk_action(WithBulkSource, :apply_all, [:a, :b], %{}) == %{
               bulk_action_items: [:a, :b]
             }
    end
  end

  describe "preview/live_preview/gui_preview helpers" do
    test "returns false for source without preview callbacks" do
      refute Source.preview?(NoActionsSource)
      refute Source.live_preview?(NoActionsSource)
      refute Source.gui_preview?(NoActionsSource)
    end

    test "live preview falls back to preview?/0 for navigation-only sources" do
      assert Source.preview?(LivePreviewOnlySource)
      assert Source.live_preview?(LivePreviewOnlySource)
      refute Source.gui_preview?(LivePreviewOnlySource)
    end

    test "preview/2 provides content but does not enable the GUI pane by itself" do
      refute Source.gui_preview?(WithPreviewSource)
    end

    test "GUI preview can be enabled explicitly without preview/2" do
      assert Source.gui_preview?(WithGuiPreviewSource)
      refute Source.preview?(WithGuiPreviewSource)
      refute Source.live_preview?(WithGuiPreviewSource)
    end
  end

  describe "preview/3" do
    test "returns nil for source without preview callback" do
      assert Source.preview(NoActionsSource, {:a, "item", "desc"}, %{}) == nil
    end

    test "returns preview lines for source with preview callback" do
      assert Source.preview(WithPreviewSource, {:a, "item", "desc"}, %{theme: %{fg: 0xFFFFFF}}) ==
               [
                 [{"preview", 0xFFFFFF, false}]
               ]
    end
  end

  describe "layout/1" do
    test "returns centered layout for project switcher" do
      assert Source.layout(ProjectSource) == :centered
    end
  end
end

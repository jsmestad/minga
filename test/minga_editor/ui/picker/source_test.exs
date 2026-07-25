defmodule MingaEditor.UI.Picker.SourceTest do
  @moduledoc "Tests for Picker.Source helper functions and optional callback fallbacks."

  use ExUnit.Case, async: true

  alias Minga.Extension.CodeLease
  alias MingaEditor.Test.PickerCallbackProbe, as: CallbackProbe
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
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
    def on_bulk_select(items, state) do
      send(self(), {:bulk_selected, items})
      state
    end

    @impl true
    def bulk_actions(_items), do: [{"Apply all", :apply_all}]

    @impl true
    def on_bulk_action(:apply_all, items, state) do
      send(self(), {:bulk_action_items, items})
      state
    end

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

  describe "on_cancel/3" do
    test "returns the unchanged state when the source omits on_cancel/1" do
      state = base_state()

      assert Source.on_cancel(NoActionsSource, state) === state
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
      state = base_state()
      assert Source.bulk_select(NoActionsSource, [:a], state) == state
    end

    test "bulk_select delegates to source with bulk callback" do
      state = base_state()
      assert Source.bulk_select(WithBulkSource, [:a, :b], state) == state
      assert_receive {:bulk_selected, [:a, :b]}
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
      state = base_state()
      assert Source.on_bulk_action(NoActionsSource, :apply_all, [:a], state) == state
    end

    test "on_bulk_action delegates to source with bulk callbacks" do
      state = base_state()
      assert Source.on_bulk_action(WithBulkSource, :apply_all, [:a, :b], state) == state
      assert_receive {:bulk_action_items, [:a, :b]}
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

  describe "callback boundary validation" do
    test "every extension picker shape reports invalid values and uses its domain fallback" do
      source = activate_source(CallbackProbe)
      state = base_state()
      context = Context.from_editor_state(state)
      item = %Item{id: :probe, label: "Probe"}
      items = [item]

      cases = [
        {:title, fn -> Source.title(CallbackProbe, source) end, ""},
        {:candidates, fn -> Source.candidates(CallbackProbe, context, source) end, []},
        {:on_select, fn -> Source.on_select(CallbackProbe, item, state, source) end, state},
        {:on_cancel, fn -> Source.on_cancel(CallbackProbe, state, source) end, state},
        {:preview?, fn -> Source.preview?(CallbackProbe, source) end, false},
        {:live_preview?, fn -> Source.live_preview?(CallbackProbe, source) end, false},
        {:gui_preview?, fn -> Source.gui_preview?(CallbackProbe, source) end, false},
        {:preview, fn -> Source.preview(CallbackProbe, item, %{}, source) end, nil},
        {:actions, fn -> Source.actions(CallbackProbe, item, source) end, []},
        {:on_action, fn -> Source.on_action(CallbackProbe, :open, item, state, source) end,
         state},
        {:on_bulk_select, fn -> Source.bulk_select(CallbackProbe, items, state, source) end,
         state},
        {:bulk_actions, fn -> Source.bulk_actions(CallbackProbe, items, source) end, []},
        {:on_bulk_action,
         fn -> Source.on_bulk_action(CallbackProbe, :open, items, state, source) end, state},
        {:layout, fn -> Source.layout(CallbackProbe, source) end, :bottom},
        {:keep_open_on_select?, fn -> Source.keep_open_on_select?(CallbackProbe, source) end,
         false},
        {:async?, fn -> Source.async?(CallbackProbe, source) end, false},
        {:async_fetch, fn -> Source.fetch(CallbackProbe, context, source) end,
         {:error, "Extension picker fetch failed"}},
        {:enrich, fn -> Source.enrich(CallbackProbe, items, source) end, items}
      ]

      Enum.each(cases, fn {function, invoke, fallback} ->
        Process.put({CallbackProbe, function}, :invalid_picker_return)
        assert invoke.() === fallback, "expected fallback for #{function}"
        Process.delete({CallbackProbe, function})
      end)
    end

    test "core picker invalid values propagate for every callback shape" do
      state = base_state()
      context = Context.from_editor_state(state)
      item = %Item{id: :probe, label: "Probe"}
      items = [item]

      cases = [
        {:title, fn -> Source.title(CallbackProbe) end},
        {:candidates, fn -> Source.candidates(CallbackProbe, context) end},
        {:on_select, fn -> Source.on_select(CallbackProbe, item, state) end},
        {:on_cancel, fn -> Source.on_cancel(CallbackProbe, state) end},
        {:preview?, fn -> Source.preview?(CallbackProbe) end},
        {:live_preview?, fn -> Source.live_preview?(CallbackProbe) end},
        {:gui_preview?, fn -> Source.gui_preview?(CallbackProbe) end},
        {:preview, fn -> Source.preview(CallbackProbe, item, %{}) end},
        {:actions, fn -> Source.actions(CallbackProbe, item) end},
        {:on_action, fn -> Source.on_action(CallbackProbe, :open, item, state) end},
        {:on_bulk_select, fn -> Source.bulk_select(CallbackProbe, items, state) end},
        {:bulk_actions, fn -> Source.bulk_actions(CallbackProbe, items) end},
        {:on_bulk_action, fn -> Source.on_bulk_action(CallbackProbe, :open, items, state) end},
        {:layout, fn -> Source.layout(CallbackProbe) end},
        {:keep_open_on_select?, fn -> Source.keep_open_on_select?(CallbackProbe) end},
        {:async?, fn -> Source.async?(CallbackProbe) end},
        {:async_fetch, fn -> Source.fetch(CallbackProbe, context) end},
        {:enrich, fn -> Source.enrich(CallbackProbe, items) end}
      ]

      Enum.each(cases, fn {function, invoke} ->
        Process.put({CallbackProbe, function}, :invalid_picker_return)
        assert_raise ArgumentError, ~r/core picker callback/, fn -> invoke.() end
        Process.delete({CallbackProbe, function})
      end)
    end
  end

  defp activate_source(module) do
    source = {:extension, unique_name(:picker_source)}
    :ok = CodeLease.activate_source(source, [module])

    on_exit(fn ->
      case CodeLease.quiesce_source(source) do
        {:ok, token} -> CodeLease.complete_unload(token)
        {:error, _reason} -> :ok
      end
    end)

    source
  end

  defp base_state do
    MingaEditor.RenderPipeline.TestHelpers.base_state(rendering: :disabled)
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end

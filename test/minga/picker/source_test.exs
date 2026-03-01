defmodule Minga.Picker.SourceTest do
  @moduledoc "Tests for Picker.Source helper functions and optional callback fallbacks."

  use ExUnit.Case, async: true

  alias Minga.Picker.Source

  defmodule NoActionsSource do
    @behaviour Minga.Picker.Source

    @impl true
    def title, do: "No actions"

    @impl true
    def candidates(_ctx), do: [{:a, "item", "desc"}]

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state
  end

  defmodule WithActionsSource do
    @behaviour Minga.Picker.Source

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

  describe "preview?/1" do
    test "returns false for source without preview? callback" do
      refute Source.preview?(NoActionsSource)
    end
  end
end

defmodule MingaEditor.UI.Picker.ThinkingLevelSourceTest do
  @moduledoc "Tests for the agent thinking level picker source."

  use ExUnit.Case, async: true

  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ThinkingLevelSource
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  describe "candidates/1" do
    test "returns the four supported thinking levels" do
      candidates = ThinkingLevelSource.candidates(context_with_level("medium"))

      assert Enum.map(candidates, & &1.id) == ["off", "low", "medium", "high"]
      assert Enum.all?(candidates, &match?(%Item{}, &1))
    end

    test "marks the current thinking level as active" do
      candidates = ThinkingLevelSource.candidates(context_with_level("high"))

      high = Enum.find(candidates, &(&1.id == "high"))
      low = Enum.find(candidates, &(&1.id == "low"))

      assert high.active == true
      assert low.active == false
    end
  end

  defp context_with_level(level) do
    %Context{
      buffers: %Buffers{},
      editing: VimState.new(),
      search: %Search{},
      viewport: Viewport.new(80, 24),
      tab_bar: %{},
      picker_ui: %{context: %{current_level: level}},
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end
end

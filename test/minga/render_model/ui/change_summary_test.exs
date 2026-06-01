defmodule Minga.RenderModel.UI.ChangeSummaryTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.ChangeSummary
  alias Minga.RenderModel.UI.ChangeSummary.Entry

  describe "%ChangeSummary{}" do
    test "defaults to a hidden (empty) summary" do
      model = %ChangeSummary{}

      assert model.entries == []
      assert model.selected_index == 0
    end

    test "carries diff-stat entries and a selected index" do
      entry = %Entry{path: "lib/a.ex", action: :modified, lines_added: 3, lines_removed: 1}
      model = %ChangeSummary{entries: [entry], selected_index: 0}

      assert [%Entry{path: "lib/a.ex", lines_added: 3, lines_removed: 1}] = model.entries
      assert model.selected_index == 0
    end
  end

  describe "%ChangeSummary.Entry{}" do
    test "requires a path and defaults action and counts" do
      entry = %Entry{path: "lib/a.ex"}

      assert entry.path == "lib/a.ex"
      assert entry.action == :modified
      assert entry.lines_added == 0
      assert entry.lines_removed == 0
    end

    test "raises when path is missing" do
      assert_raise ArgumentError, fn ->
        struct!(Entry, %{})
      end
    end
  end
end

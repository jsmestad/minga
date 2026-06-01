defmodule MingaEditor.RenderModel.UI.ChangeSummaryBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.ChangeSummaryBuilder
  alias Minga.RenderModel.UI.ChangeSummary

  describe "build/1" do
    test "builds a hidden (empty) summary when payload is nil" do
      assert %ChangeSummary{entries: [], selected_index: 0} = ChangeSummaryBuilder.build(nil)
    end

    test "builds a hidden summary when payload is not a board" do
      assert %ChangeSummary{entries: []} = ChangeSummaryBuilder.build({:other, %{}})
    end

    test "builds a hidden summary when the board has no zoomed card" do
      assert %ChangeSummary{entries: []} =
               ChangeSummaryBuilder.build({:board, %{zoomed_card_id: nil}})
    end

    test "builds a summary for a zoomed board card" do
      # Diff stats are not computed yet (tracked TODO), so the card currently
      # yields an empty entry list; this asserts the build path resolves.
      assert %ChangeSummary{entries: [], selected_index: 0} =
               ChangeSummaryBuilder.build({:board, %{zoomed_card_id: 42}})
    end
  end
end

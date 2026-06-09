defmodule MingaEditor.RenderModel.UI.ChangeSummaryBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.ChangeSummary
  alias MingaEditor.RenderModel.UI.ChangeSummaryBuilder

  describe "build/1" do
    test "builds a hidden summary for unsupported shell payloads" do
      assert %ChangeSummary{entries: [], selected_index: 0} =
               ChangeSummaryBuilder.build({:unknown, %{}})
    end
  end
end

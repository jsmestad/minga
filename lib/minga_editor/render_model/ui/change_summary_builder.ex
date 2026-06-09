defmodule MingaEditor.RenderModel.UI.ChangeSummaryBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.ChangeSummary

  @spec build(term()) :: ChangeSummary.t()
  def build(_gui_payload) do
    %ChangeSummary{}
  end
end

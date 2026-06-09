defmodule MingaEditor.RenderModel.UI.AgentContextBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.AgentContext

  @spec build(term()) :: AgentContext.t()
  def build(_other) do
    %AgentContext{visible: false}
  end
end

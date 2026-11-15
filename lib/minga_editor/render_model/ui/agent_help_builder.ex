defmodule MingaEditor.RenderModel.UI.AgentHelpBuilder do
  @moduledoc false

  alias Minga.Keymap.Scope.Agent
  alias Minga.RenderModel.UI.AgentHelp
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Frontend.Emit.Context

  @spec build(Context.t()) :: AgentHelp.t()
  def build(%Context{workspace: %{agent_ui: %{view: %{help_visible: true} = view}}}) do
    %AgentHelp{visible?: true, groups: Agent.help_groups(View.focus(view))}
  end

  def build(%Context{}), do: %AgentHelp{}
end

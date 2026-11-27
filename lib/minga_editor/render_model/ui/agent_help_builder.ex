defmodule MingaEditor.RenderModel.UI.AgentHelpBuilder do
  @moduledoc false

  alias Minga.Keymap.Scope.Agent
  alias Minga.RenderModel.UI.AgentHelp
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Emit.Context

  @spec build(Context.t()) :: AgentHelp.t()
  def build(%Context{workspace: %{agent_ui: %{view: %{help_visible: true} = view}}} = ctx) do
    %AgentHelp{visible?: true, groups: groups(view, ctx.intent.frame)}
  end

  def build(%Context{}), do: %AgentHelp{}

  # Over a staged Diff Review, Help leads with the review keys of the active
  # editing model, from the same table that binds them.
  @spec groups(View.t(), MingaEditor.RenderPipeline.FrameIntent.t()) ::
          [Minga.Keymap.Scope.help_group()]
  defp groups(view, frame) do
    if View.decision_review?(view) do
      keys = Agent.diff_review_key_set(frame.editing_model, Capabilities.gui?(frame.capabilities))
      [Agent.diff_review_help_group(keys) | Agent.help_groups(View.focus(view))]
    else
      Agent.help_groups(View.focus(view))
    end
  end
end

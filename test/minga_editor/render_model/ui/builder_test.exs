defmodule MingaEditor.RenderModel.UI.BuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.Builder
  alias Minga.RenderModel
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.TestHelpers

  describe "build_ui/1" do
    test "module is defined and exports build_ui/1" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Builder)
      assert function_exported?(Builder, :build_ui, 1)
    end

    test "returns a UI struct with theme, breadcrumb, and notifications populated" do
      ctx = build_minimal_context()
      {ui, _ctx} = Builder.build_ui(ctx)

      assert %RenderModel.UI{} = ui
      assert %Minga.RenderModel.UI.Theme{} = ui.theme
      assert ui.theme.name == ctx.intent.frame.theme.name
      assert is_list(ui.theme.color_slots)
      assert %Minga.RenderModel.UI.Breadcrumb{} = ui.breadcrumb
      assert ui.breadcrumb.segments == []
      assert %Minga.RenderModel.UI.Notifications{} = ui.notifications
      assert ui.notifications.items == []
      assert %Minga.RenderModel.UI.SearchState{} = ui.search_state
      assert ui.search_state.active == false
      assert %Minga.RenderModel.UI.GitStatus{} = ui.git_status
      assert ui.git_status.repo_state == :not_a_repo
    end

    # The builder fills UI fields from the emit context; values are stubs here.
    defp build_minimal_context do
      TestHelpers.base_state(port_manager: nil)
      |> Context.from_editor_state()
    end
  end
end

defmodule MingaEditor.RenderModel.UI.BuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.Builder
  alias Minga.RenderModel

  describe "build_ui/1" do
    test "module is defined and exports build_ui/1" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Builder)
      assert function_exported?(Builder, :build_ui, 1)
    end

    test "returns a UI struct with theme, breadcrumb, and notifications populated" do
      ctx = build_minimal_context()
      ui = Builder.build_ui(ctx)

      assert %RenderModel.UI{} = ui
      assert %Minga.RenderModel.UI.Theme{} = ui.theme
      assert ui.theme.name == ctx.theme.name
      assert is_list(ui.theme.color_slots)
      assert %Minga.RenderModel.UI.Breadcrumb{} = ui.breadcrumb
      assert ui.breadcrumb.file_path == nil
      assert ui.breadcrumb.root == ""
      assert %Minga.RenderModel.UI.Notifications{} = ui.notifications
      assert ui.notifications.items == []
      assert %Minga.RenderModel.UI.SearchState{} = ui.search_state
      assert ui.search_state.active == false
      assert %Minga.RenderModel.UI.GitStatus{} = ui.git_status
      assert ui.git_status.repo_state == :not_a_repo
    end

    # Build a minimal emit context with just the required keys.
    # The builder doesn't read any fields yet, so values are stubs.
    defp build_minimal_context do
      %MingaEditor.Frontend.Emit.Context{
        port_manager: self(),
        capabilities: MingaEditor.Frontend.Capabilities.default(),
        theme: MingaEditor.UI.Theme.get!(:doom_one),
        font_registry: MingaEditor.UI.FontRegistry.new(),
        windows: %MingaEditor.State.Windows{map: %{}, active: 1},
        layout: %MingaEditor.Layout{
          terminal: {0, 0, 80, 24},
          editor_area: {0, 0, 80, 24},
          minibuffer: {23, 0, 80, 1},
          window_layouts: %{}
        },
        shell: MingaEditor.Shell.Traditional
      }
    end
  end
end

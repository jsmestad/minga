defmodule Minga.RenderModel.UITest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI

  describe "%UI{}" do
    test "creates a struct with all nil fields" do
      ui = %UI{}

      assert ui.theme == nil
      assert ui.breadcrumb == nil
      assert ui.which_key == nil
      assert ui.notifications == nil
      assert ui.search_state == nil
      assert ui.git_status == nil
      assert ui.agent_context == nil
      assert ui.status_bar == nil
      assert ui.observatory == nil
      assert ui.board == nil
      assert ui.tab_bar == nil
      assert ui.workspaces == nil
      assert ui.sidebars == nil
      assert ui.file_tree == nil
      assert ui.extension_overlay == nil
      assert ui.extension_panel == nil
      assert ui.hover_popup == nil
      assert ui.float_popup == nil
    end
  end
end

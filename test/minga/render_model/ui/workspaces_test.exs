defmodule Minga.RenderModel.UI.WorkspacesTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Workspaces
  alias Minga.RenderModel.UI.Workspaces.VisibleTab
  alias Minga.RenderModel.UI.Workspaces.Workspace

  describe "%Workspaces{}" do
    test "defaults to hidden with no entries" do
      workspaces = %Workspaces{}

      refute workspaces.visible?
      assert workspaces.workspaces == []
      assert workspaces.visible_tabs == []
    end

    test "carries workspace and visible tab summaries" do
      workspace = %Workspace{id: 0, kind: :manual, label: "Files", icon: "folder"}
      tab = %VisibleTab{id: 10, workspace_id: 0, label: "lib.ex", icon: ""}
      workspaces = %Workspaces{visible?: true, workspaces: [workspace], visible_tabs: [tab]}

      assert workspaces.workspaces == [workspace]
      assert workspaces.visible_tabs == [tab]
    end
  end
end

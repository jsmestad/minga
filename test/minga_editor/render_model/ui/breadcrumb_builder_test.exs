defmodule MingaEditor.RenderModel.UI.BreadcrumbBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.BreadcrumbBuilder
  alias Minga.RenderModel.UI.Breadcrumb

  describe "build/2" do
    test "produces a Breadcrumb model with file_path and root" do
      model = BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "/home/user/project")

      assert %Breadcrumb{} = model
      assert model.file_path == "/home/user/project/lib/foo.ex"
      assert model.root == "/home/user/project"
    end

    test "produces a Breadcrumb model with nil file_path" do
      model = BreadcrumbBuilder.build(nil, "/home/user/project")

      assert %Breadcrumb{} = model
      assert model.file_path == nil
      assert model.root == "/home/user/project"
    end

    test "produces a Breadcrumb model with empty root" do
      model = BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "")

      assert %Breadcrumb{} = model
      assert model.root == ""
    end
  end
end

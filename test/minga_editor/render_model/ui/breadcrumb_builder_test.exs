defmodule MingaEditor.RenderModel.UI.BreadcrumbBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.BreadcrumbBuilder
  alias Minga.RenderModel.UI.Breadcrumb

  describe "build/2" do
    test "produces a Breadcrumb model with file_path, root, and derived segments" do
      model = BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "/home/user/project")

      assert %Breadcrumb{} = model
      assert model.file_path == "/home/user/project/lib/foo.ex"
      assert model.root == "/home/user/project"
      # The builder owns the Path.relative_to/split derivation (ruling 4).
      assert model.segments == ["lib", "foo.ex"]
    end

    test "produces a Breadcrumb model with nil file_path and empty segments" do
      model = BreadcrumbBuilder.build(nil, "/home/user/project")

      assert %Breadcrumb{} = model
      assert model.file_path == nil
      assert model.root == "/home/user/project"
      assert model.segments == []
    end

    test "produces a Breadcrumb model with empty root" do
      model = BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "")

      assert %Breadcrumb{} = model
      assert model.root == ""
    end

    test "derives unicode path segments" do
      model = BreadcrumbBuilder.build("/root/λ/café→.ex", "/root")

      assert model.segments == ["λ", "café→.ex"]
    end
  end
end

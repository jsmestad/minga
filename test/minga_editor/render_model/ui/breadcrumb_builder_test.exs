defmodule MingaEditor.RenderModel.UI.BreadcrumbBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.BreadcrumbBuilder
  alias Minga.RenderModel.UI.Breadcrumb

  describe "build/2" do
    test "produces a Breadcrumb model with derived segments" do
      model = BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "/home/user/project")

      assert %Breadcrumb{segments: ["lib", "foo.ex"]} = model
    end

    test "produces a Breadcrumb model with nil file_path and empty segments" do
      model = BreadcrumbBuilder.build(nil, "/home/user/project")

      assert %Breadcrumb{segments: []} = model
    end

    test "produces a Breadcrumb model with empty root" do
      model = BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "")

      assert %Breadcrumb{segments: ["/", "home", "user", "project", "lib", "foo.ex"]} = model
    end

    test "derives unicode path segments" do
      model = BreadcrumbBuilder.build("/root/λ/café→.ex", "/root")

      assert model.segments == ["λ", "café→.ex"]
    end
  end
end

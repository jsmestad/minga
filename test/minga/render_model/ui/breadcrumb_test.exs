defmodule Minga.RenderModel.UI.BreadcrumbTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Breadcrumb

  describe "%Breadcrumb{}" do
    test "requires root" do
      bc = %Breadcrumb{root: "/home/user/project"}

      assert bc.root == "/home/user/project"
      assert bc.file_path == nil
    end

    test "raises when root is missing" do
      assert_raise ArgumentError, fn ->
        struct!(Breadcrumb, %{})
      end
    end

    test "accepts file_path and root" do
      bc = %Breadcrumb{file_path: "/home/user/project/lib/foo.ex", root: "/home/user/project"}

      assert bc.file_path == "/home/user/project/lib/foo.ex"
      assert bc.root == "/home/user/project"
    end
  end
end

defmodule Minga.Frontend.Adapter.GUI.BreadcrumbEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Breadcrumb
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_breadcrumb Minga.Protocol.Opcodes.gui_breadcrumb()

  describe "encode/2" do
    test "encodes nil file_path as empty breadcrumb" do
      model = %Breadcrumb{file_path: nil, root: "/home/user/project"}
      caches = Caches.new()

      {cmd, _caches} = BreadcrumbEncoder.encode(model, caches)

      assert <<@op_gui_breadcrumb, 0::8>> = cmd
    end

    test "encodes file_path with segments" do
      model = %Breadcrumb{
        file_path: "/home/user/project/lib/foo.ex",
        root: "/home/user/project"
      }

      caches = Caches.new()
      {cmd, _caches} = BreadcrumbEncoder.encode(model, caches)

      assert <<@op_gui_breadcrumb, 2::8, rest::binary>> = cmd
      # Two segments: "lib" and "foo.ex"
      assert <<3::16, "lib", 6::16, "foo.ex">> = rest
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = %Breadcrumb{
        file_path: "/home/user/project/lib/foo.ex",
        root: "/home/user/project"
      }

      caches = Caches.new()
      {cmd1, caches} = BreadcrumbEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = BreadcrumbEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when model changes" do
      model1 = %Breadcrumb{file_path: "/project/lib/foo.ex", root: "/project"}
      model2 = %Breadcrumb{file_path: "/project/lib/bar.ex", root: "/project"}

      caches = Caches.new()
      {cmd1, caches} = BreadcrumbEncoder.encode(model1, caches)
      assert cmd1 != nil

      {cmd2, _caches} = BreadcrumbEncoder.encode(model2, caches)
      assert cmd2 != nil
    end

    test "produces byte-identical output to legacy ProtocolGUI.encode_gui_breadcrumb/2" do
      test_cases = [
        {nil, "/home/user/project"},
        {"/home/user/project/lib/foo.ex", "/home/user/project"},
        {"/home/user/project/lib/sub/deep.ex", "/home/user/project"},
        {"/home/user/project/mix.exs", "/home/user/project"}
      ]

      for {file_path, root} <- test_cases do
        legacy_binary = ProtocolGUI.encode_gui_breadcrumb(file_path, root)

        model = %Breadcrumb{file_path: file_path, root: root}
        caches = Caches.new()
        {new_binary, _caches} = BreadcrumbEncoder.encode(model, caches)

        assert new_binary == legacy_binary,
               "Breadcrumb (#{inspect(file_path)}, #{inspect(root)}): new encoder output does not match legacy output"
      end
    end
  end
end

defmodule Minga.Frontend.Adapter.GUI.BreadcrumbEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Breadcrumb
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.RenderModel.UI.BreadcrumbBuilder

  @op_gui_breadcrumb Minga.Protocol.Opcodes.gui_breadcrumb()

  describe "encode/2" do
    test "encodes nil file_path as empty breadcrumb" do
      model = BreadcrumbBuilder.build(nil, "/home/user/project")
      caches = Caches.new()

      {cmd, _caches} = BreadcrumbEncoder.encode(model, caches)

      assert <<@op_gui_breadcrumb, 0::8>> = cmd
    end

    test "encodes file_path with segments" do
      model = BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "/home/user/project")

      caches = Caches.new()
      {cmd, _caches} = BreadcrumbEncoder.encode(model, caches)

      assert <<@op_gui_breadcrumb, 2::8, rest::binary>> = cmd
      # Two segments: "lib" and "foo.ex"
      assert <<3::16, "lib", 6::16, "foo.ex">> = rest
    end

    test "encodes a model with explicit segments straight through" do
      # The shell consumes the builder-derived segment list directly.
      model = %Breadcrumb{file_path: "ignored", root: "/", segments: ["a", "bb"]}

      {cmd, _caches} = BreadcrumbEncoder.encode(model, Caches.new())

      assert cmd == <<@op_gui_breadcrumb, 2::8, 1::16, "a", 2::16, "bb">>
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "/home/user/project")

      caches = Caches.new()
      {cmd1, caches} = BreadcrumbEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = BreadcrumbEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when model changes" do
      model1 = BreadcrumbBuilder.build("/project/lib/foo.ex", "/project")
      model2 = BreadcrumbBuilder.build("/project/lib/bar.ex", "/project")

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
        {"/home/user/project/mix.exs", "/home/user/project"},
        # Unicode segments and a max-length (255-byte) segment exercise the
        # relocated derivation and the string16 element layout.
        {"/home/user/project/λ/café→.ex", "/home/user/project"},
        {"/home/user/project/#{String.duplicate("x", 255)}.ex", "/home/user/project"}
      ]

      for {file_path, root} <- test_cases do
        legacy_binary = ProtocolGUI.encode_gui_breadcrumb(file_path, root)

        model = BreadcrumbBuilder.build(file_path, root)
        caches = Caches.new()
        {new_binary, _caches} = BreadcrumbEncoder.encode(model, caches)

        assert new_binary == legacy_binary,
               "Breadcrumb (#{inspect(file_path)}, #{inspect(root)}): new encoder output does not match legacy output"
      end
    end
  end
end

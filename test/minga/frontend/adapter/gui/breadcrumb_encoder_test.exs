defmodule Minga.Frontend.Adapter.GUI.BreadcrumbEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.EncodingError
  alias Minga.RenderModel.UI.Breadcrumb
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
      model = %Breadcrumb{segments: ["a", "bb"]}

      {cmd, _caches} = BreadcrumbEncoder.encode(model, Caches.new())

      assert cmd == <<@op_gui_breadcrumb, 2::8, 1::16, "a", 2::16, "bb">>
    end

    test "rejects a segment count beyond the uint8 carrier" do
      model = %Breadcrumb{segments: List.duplicate("a", 256)}

      assert %{
               command: :gui_breadcrumb,
               field: :segments,
               field_path: [:segments],
               actual: 256,
               min: 0,
               max: 255
             } =
               assert_raise(EncodingError, fn -> BreadcrumbEncoder.encode(model, Caches.new()) end)
    end

    test "rejects a segment beyond the string16 carrier" do
      model = %Breadcrumb{segments: [String.duplicate("a", 65_536)]}

      assert %{
               command: :gui_breadcrumb,
               field: :segments,
               field_path: [:segments, 0],
               actual: 65_536,
               min: 0,
               max: 65_535
             } =
               assert_raise(EncodingError, fn -> BreadcrumbEncoder.encode(model, Caches.new()) end)
    end

    test "suppresses equal visible segments from different source path and root inputs" do
      model1 = BreadcrumbBuilder.build("/repo_a/lib/foo.ex", "/repo_a")
      model2 = BreadcrumbBuilder.build("/repo_b/lib/foo.ex", "/repo_b")

      caches = Caches.new()
      {cmd1, caches} = BreadcrumbEncoder.encode(model1, caches)
      assert cmd1 != nil

      {cmd2, _caches} = BreadcrumbEncoder.encode(model2, caches)
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

    # Byte-exactness against the schema-generated codec is proven by the
    # cross-language golden tests (test/support/protocol_golden.ex +
    # go/tui/internal/protocol/golden_cross_lang_test.go), which replaced the
    # former hand-written ProtocolGUI.encode_gui_breadcrumb parity oracle for
    # this family. The case below decodes the production wire format and asserts
    # on the decoded segments, preserving the path-derivation coverage (nil
    # path, nested dirs, root-level file, unicode, max-length segment) the
    # oracle-anchored test carried.
    test "encodes the builder-derived segments into the string16 list wire layout" do
      test_cases = [
        {{nil, "/home/user/project"}, []},
        {{"/home/user/project/lib/foo.ex", "/home/user/project"}, ["lib", "foo.ex"]},
        {{"/home/user/project/lib/sub/deep.ex", "/home/user/project"}, ["lib", "sub", "deep.ex"]},
        {{"/home/user/project/mix.exs", "/home/user/project"}, ["mix.exs"]},
        # Unicode segments and a max-length (255-byte) segment exercise the
        # relocated derivation and the string16 element layout.
        {{"/home/user/project/λ/café→.ex", "/home/user/project"}, ["λ", "café→.ex"]},
        {{"/home/user/project/#{String.duplicate("x", 255)}.ex", "/home/user/project"},
         ["#{String.duplicate("x", 255)}.ex"]}
      ]

      for {{file_path, root}, expected_segments} <- test_cases do
        model = BreadcrumbBuilder.build(file_path, root)
        {cmd, _caches} = BreadcrumbEncoder.encode(model, Caches.new())

        assert decode_breadcrumb(cmd) == expected_segments,
               "Breadcrumb (#{inspect(file_path)}, #{inspect(root)}): unexpected decoded segments"
      end
    end
  end

  # Decodes the production gui_breadcrumb wire format: opcode(1) + count(1) then
  # `count` string16 segments.
  defp decode_breadcrumb(<<@op_gui_breadcrumb, count::8, rest::binary>>) do
    decode_segments(rest, count, [])
  end

  defp decode_segments(_rest, 0, acc), do: Enum.reverse(acc)

  defp decode_segments(<<len::16, seg::binary-size(len), rest::binary>>, n, acc) do
    decode_segments(rest, n - 1, [seg | acc])
  end
end

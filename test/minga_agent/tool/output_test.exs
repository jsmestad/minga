defmodule MingaAgent.Tool.OutputTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Codec
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output.Revision

  test "presentation truncation cannot claim recovery without retained bytes" do
    {:ok, full} = Range.new(:full, :bytes, 0, 20, 20)

    assert {:error, :invalid_output} =
             Output.new("first ten!", :complete, full, presentation: {:truncated, 10})

    reference = reference("first ten!second ten")

    assert {:ok, output} =
             Output.new("first ten!", :complete, full,
               presentation: {:truncated, 10},
               reference: reference
             )

    assert {:ok, ^output} = Output.result(output)
  end

  test "requested ranges and pages are complete selections, not incomplete captures" do
    for {kind, unit, start, count, total} <- [
          {:requested, :lines, 9, 2, 30},
          {:page, :items, 100, 100, 200}
        ] do
      {:ok, selection} = Range.new(kind, unit, start, count, total)
      {:ok, output} = Output.new("selected content", :complete, selection)
      assert {:ok, ^output} = Output.result(output)
      assert output.presentation == :complete
    end
  end

  test "retained pages of incomplete captures remain tool errors" do
    for kind <- [:captured_prefix, :requested, :page] do
      {:ok, selection} = Range.new(kind, :bytes, 0, 10, :unknown)
      {:ok, output} = Output.new("retained!!", {:incomplete, :capture_byte_limit}, selection)
      assert {:error, ^output} = Output.result(output)
    end

    {:ok, prefix} = Range.new(:captured_prefix, :bytes, 0, 10, :unknown)
    assert {:error, :invalid_output} = Output.new("retained!!", :complete, prefix)
  end

  test "a full range cannot hide an omitted interval or invent an unknown total" do
    for bounds <- [{1, 9, 10}, {0, 9, 10}, {0, 10, :unknown}] do
      {start, count, total} = bounds
      assert {:error, :invalid_range} = Range.new(:full, :bytes, start, count, total)
    end

    assert {:error, :invalid_range} = Range.new(:page, :items, 9, 2, 10)
    assert {:ok, _} = Range.new(:full, :bytes, 0, 0, 0)
  end

  test "same-size content changes alter a revision without depending on file metadata" do
    {:ok, range} = Range.new(:full, :bytes, 0, 4, 4)

    {:ok, before} =
      Revision.new(
        source_kind: :disk,
        source_id: "/project/file",
        scope: range,
        sha256: Reference.digest("aaaa")
      )

    {:ok, after_change} =
      Revision.new(
        source_kind: :disk,
        source_id: "/project/file",
        scope: range,
        sha256: Reference.digest("bbbb")
      )

    assert Revision.token(before) != Revision.token(after_change)
    assert Revision.full_source?(before)

    {:ok, requested} = Range.new(:requested, :bytes, 0, 4, 4)

    {:ok, scoped} =
      Revision.new(
        source_kind: :disk,
        source_id: "/project/file",
        scope: requested,
        sha256: before.sha256
      )

    refute Revision.full_source?(scoped)
    assert Revision.token(scoped) != Revision.token(before)
  end

  test "persisted output preserves incomplete status while rejecting invalid or unknown schemas" do
    {:ok, page} = Range.new(:page, :bytes, 0, 10, :unknown)

    {:ok, output} =
      Output.new("retained!!", {:incomplete, :interrupted}, page,
        reference: reference("retained!!")
      )

    encoded = output |> Codec.encode() |> JSON.encode!() |> JSON.decode!()
    assert {:ok, restored} = Codec.decode(encoded)
    assert {:error, ^restored} = Output.result(restored)
    assert restored.view == "retained!!"
    assert restored.reference.sha256 == Reference.digest("retained!!")

    assert {:error, :unsupported_output_version} =
             Codec.decode(Map.put(encoded, "output_version", 2))

    assert {:error, :invalid_output} = Codec.decode(Map.put(encoded, "view", nil))

    assert {:error, :invalid_output} =
             Codec.decode(
               Map.put(encoded, "capture", %{
                 "status" => "incomplete",
                 "reason" => "not_a_supported_capture_outcome"
               })
             )
  end

  defp reference(bytes) do
    {:ok, token} = Reference.token("durable-session", String.duplicate("a", 32))

    {:ok, reference} =
      Reference.new(
        token: token,
        media_type: "text/plain",
        bytes: byte_size(bytes),
        sha256: Reference.digest(bytes)
      )

    reference
  end
end

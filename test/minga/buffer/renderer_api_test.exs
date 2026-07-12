defmodule Minga.Buffer.RendererAPITest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.RenderSnapshot
  alias Minga.Buffer.RendererConsume

  test "renderer consume atomically returns lineage metadata and advances only renderer" do
    buffer = start_supervised!({Buffer, content: "one\ntwo"})
    first = Buffer.renderer_consume(buffer)

    assert %RendererConsume{version: 0, line_count: 2, change_sequence: 0, changes: {:ok, []}} =
             first

    :ok = Buffer.move_to(buffer, {0, 3})
    :ok = Buffer.insert_text(buffer, "\nnew")

    assert %RendererConsume{version: 1, line_count: 3, change_sequence: 1, changes: {:ok, [_]}} =
             Buffer.renderer_consume(buffer)

    assert {:ok, []} = Buffer.consume_edit_deltas(buffer, :renderer)
  end

  test "version-checked range fetch returns no Document and rejects an intervening edit" do
    buffer = start_supervised!({Buffer, content: "zero\none\ntwo\nthree"})
    consume = Buffer.renderer_consume(buffer)

    assert {:ok, %RenderSnapshot{lines: ["one", "two"], first_line: 1} = view} =
             Buffer.render_lines(buffer, consume.version, 1, 2)

    refute Map.has_key?(Map.from_struct(view), :document)
    assert :erlang.external_size(view) < 10_000

    :ok = Buffer.insert_text(buffer, "changed")
    assert :stale = Buffer.render_lines(buffer, consume.version, 1, 2)
  end
end

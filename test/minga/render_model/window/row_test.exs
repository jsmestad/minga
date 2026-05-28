defmodule Minga.RenderModel.Window.RowTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.Window.Row

  describe "stable_id/4" do
    test "is deterministic for the same durable row inputs" do
      assert Row.stable_id(:normal, 12, 0, 0) == Row.stable_id(:normal, 12, 0, 0)
    end

    test "distinguishes row kinds, wrapped continuations, and decoration discriminators" do
      ids = [
        Row.stable_id(:normal, 12, 0, 0),
        Row.stable_id(:wrap_continuation, 12, 1, 0),
        Row.stable_id(:fold_start, 12, 0, 0),
        Row.stable_id(:virtual_line, 12, 0, 1),
        Row.stable_id(:block, 12, 1, 2)
      ]

      assert Enum.uniq(ids) == ids
    end
  end

  describe "stable_decoration_id/3" do
    test "is deterministic for virtual text and block decoration identities" do
      vt_id = make_ref()
      block_id = make_ref()

      assert Row.stable_decoration_id(:virtual_line, 12, vt_id) ==
               Row.stable_decoration_id(:virtual_line, 12, vt_id)

      assert Row.stable_decoration_id(:virtual_line, 12, vt_id) !=
               Row.stable_decoration_id(:virtual_line, 12, make_ref())

      assert Row.stable_decoration_id(:block, 12, {block_id, 0}) !=
               Row.stable_decoration_id(:block, 12, {block_id, 1})

      assert Row.stable_decoration_id(:fold_start, 12, block_id) ==
               Row.stable_decoration_id(:fold_start, 12, block_id)
    end
  end
end

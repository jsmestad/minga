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
end

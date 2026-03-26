defmodule Minga.Integration.GutterIconSnapshotTest do
  @moduledoc """
  Snapshot test for gutter icon annotation rendering.

  Verifies that :gutter_icon annotations render in the sign column
  when no diagnostic or git sign occupies the slot.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Core.Decorations
  alias Minga.Buffer.Server, as: BufferServer

  describe "gutter icon annotations" do
    test "gutter icon renders in sign column" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id, decs} =
          Decorations.add_annotation(decs, 1, "●",
            kind: :gutter_icon,
            fg: 0xFF6C6B,
            group: :bookmarks
          )

        decs
      end)

      # Drain pending messages and capture render with gutter icon.
      send_key(ctx, 27)
      send_key(ctx, 27)

      assert_screen_snapshot(ctx, "gutter_icon_in_sign_column")
    end
  end
end

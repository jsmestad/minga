defmodule Minga.Integration.AnnotationSnapshotTest do
  @moduledoc """
  Snapshot tests for line annotation rendering.

  Verifies that annotations (pill badges, inline text) appear correctly
  after line content in the TUI rendering path.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Core.Decorations

  describe "line annotations" do
    test "inline pill renders with background after line content" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id, decs} =
          Decorations.add_annotation(decs, 0, "work",
            kind: :inline_pill,
            fg: 0xFFFFFF,
            bg: 0x6366F1,
            group: :test_tags
          )

        decs
      end)

      # Two ESC presses: the first drains pending editor messages after
      # batch_decorations; the second ensures the decoration-changed
      # notification is processed and a render frame is captured.
      send_key(ctx, 27)
      send_key(ctx, 27)

      assert_screen_snapshot(ctx, "annotation_inline_pill")
    end

    test "inline text renders without background after line content" do
      ctx = start_editor("hello world\nsecond line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id, decs} =
          Decorations.add_annotation(decs, 0, "J. Smith, 2d ago",
            kind: :inline_text,
            fg: 0x888888,
            group: :git_blame
          )

        decs
      end)

      # Drain pending messages and capture render with annotations.
      send_key(ctx, 27)
      send_key(ctx, 27)

      assert_screen_snapshot(ctx, "annotation_inline_text")
    end

    test "multiple annotations on same line render horizontally" do
      ctx = start_editor("* TODO Meeting notes\nsecond line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id, decs} =
          Decorations.add_annotation(decs, 0, "work",
            kind: :inline_pill,
            fg: 0xFFFFFF,
            bg: 0x6366F1,
            group: :org_tags
          )

        {_id, decs} =
          Decorations.add_annotation(decs, 0, "urgent",
            kind: :inline_pill,
            fg: 0xFFFFFF,
            bg: 0xDC2626,
            group: :org_tags
          )

        decs
      end)

      # Drain pending messages and capture render with annotations.
      send_key(ctx, 27)
      send_key(ctx, 27)

      assert_screen_snapshot(ctx, "annotation_multiple_pills")
    end

    test "annotations render after EOL virtual text" do
      ctx = start_editor("hello world\nsecond line")

      BufferServer.batch_decorations(ctx.buffer, fn decs ->
        {_id, decs} =
          Decorations.add_virtual_text(decs, {0, 0},
            segments: [{"← hint", Minga.UI.Face.new(fg: 0x555555, italic: true)}],
            placement: :eol,
            group: :test_hints
          )

        {_id, decs} =
          Decorations.add_annotation(decs, 0, "tag",
            kind: :inline_pill,
            fg: 0xFFFFFF,
            bg: 0x6366F1,
            group: :test_tags
          )

        decs
      end)

      # Drain pending messages and capture render with annotations.
      send_key(ctx, 27)
      send_key(ctx, 27)

      assert_screen_snapshot(ctx, "annotation_after_virtual_text")
    end
  end
end

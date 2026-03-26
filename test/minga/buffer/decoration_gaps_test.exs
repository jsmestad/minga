defmodule Minga.Buffer.DecorationGapsTest do
  @moduledoc "Tests for #611 decoration system gap fixes."
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Core.Decorations
  alias Minga.Core.IntervalTree

  describe "content replacement clears decorations" do
    test "replace_content_force resets decorations" do
      {:ok, pid} = BufferServer.start_link(content: "hello world")

      # Add a decoration
      :ok =
        BufferServer.batch_decorations(pid, fn decs ->
          {_id, decs} =
            Decorations.add_highlight(decs, {0, 0}, {0, 5},
              style: Minga.UI.Face.new(fg: 0xFF0000)
            )

          decs
        end)

      # Verify it exists
      decs = BufferServer.decorations(pid)
      assert decs.version > 0

      # Replace content
      :ok = BufferServer.replace_content_force(pid, "new content")

      # Decorations should be cleared
      decs = BufferServer.decorations(pid)
      assert decs.highlights == nil || IntervalTree.size(decs.highlights) == 0
      assert decs.virtual_texts == []
    end

    test "reload resets decorations" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "deco_test_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "original")

      {:ok, pid} = BufferServer.start_link(file_path: path)

      # Add decoration
      BufferServer.batch_decorations(pid, fn decs ->
        {_id, decs} =
          Decorations.add_virtual_text(decs, {0, 0},
            segments: [{"hint", Minga.UI.Face.new()}],
            placement: :eol
          )

        decs
      end)

      decs = BufferServer.decorations(pid)
      assert length(decs.virtual_texts) == 1

      # Reload
      File.write!(path, "updated")
      :ok = BufferServer.reload(pid)

      # Decorations cleared
      decs = BufferServer.decorations(pid)
      assert decs.virtual_texts == []

      File.rm(path)
    end
  end

  describe "remove_group/2 clears all decoration types" do
    test "removes highlights, virtual texts, blocks, and folds by group" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_highlight(decs, {0, 0}, {0, 5},
          style: Minga.UI.Face.new(fg: 0xFF0000),
          group: :test_group
        )

      {_id, decs} =
        Decorations.add_virtual_text(decs, {0, 0},
          segments: [{"hint", Minga.UI.Face.new()}],
          placement: :eol,
          group: :test_group
        )

      {_id, decs} =
        Decorations.add_block_decoration(decs, 0,
          placement: :above,
          render: fn _w -> [{"block", Minga.UI.Face.new()}] end,
          group: :test_group
        )

      {_id, decs} =
        Decorations.add_fold_region(decs, 0, 5, group: :test_group)

      # Also add decorations from another group
      {_id, decs} =
        Decorations.add_highlight(decs, {1, 0}, {1, 5},
          style: Minga.UI.Face.new(fg: 0x00FF00),
          group: :other_group
        )

      # Remove test_group
      decs = Decorations.remove_group(decs, :test_group)

      # test_group decorations are gone
      assert decs.virtual_texts == []
      assert decs.block_decorations == []
      assert decs.fold_regions == []

      # other_group highlight survives
      highlights = IntervalTree.to_list(decs.highlights)
      assert length(highlights) == 1
    end

    test "remove_group with term() key" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_highlight(decs, {0, 0}, {0, 3},
          style: Minga.UI.Face.new(fg: 0xFF0000),
          group: {:lsp, :elixir_ls}
        )

      {_id, decs} =
        Decorations.add_highlight(decs, {1, 0}, {1, 3},
          style: Minga.UI.Face.new(fg: 0x00FF00),
          group: {:lsp, :rust_analyzer}
        )

      decs = Decorations.remove_group(decs, {:lsp, :elixir_ls})
      highlights = IntervalTree.to_list(decs.highlights)
      assert length(highlights) == 1
    end
  end

  describe "replace_content_with_decorations/4" do
    test "atomically replaces content and decorations" do
      {:ok, pid} = BufferServer.start_link(content: "old")

      BufferServer.replace_content_with_decorations(
        pid,
        "new content",
        fn decs ->
          {_id, decs} =
            Decorations.add_highlight(decs, {0, 0}, {0, 3},
              style: Minga.UI.Face.new(fg: 0xFF0000)
            )

          decs
        end
      )

      assert BufferServer.content(pid) == "new content"
      decs = BufferServer.decorations(pid)
      highlights = IntervalTree.to_list(decs.highlights)
      assert length(highlights) == 1
    end

    test "supports cursor option" do
      {:ok, pid} = BufferServer.start_link(content: "old")

      BufferServer.replace_content_with_decorations(
        pid,
        "line1\nline2",
        fn decs -> decs end,
        cursor: {1, 0}
      )

      assert BufferServer.cursor(pid) == {1, 0}
    end
  end

  describe "virtual text line cache" do
    test "virtual_texts_for_line uses cache for O(1) lookup" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_virtual_text(decs, {0, 5},
          segments: [{"hint1", Minga.UI.Face.new()}],
          placement: :eol
        )

      {_id, decs} =
        Decorations.add_virtual_text(decs, {2, 0},
          segments: [{"hint2", Minga.UI.Face.new()}],
          placement: :eol
        )

      # First call builds cache
      vts_line0 = Decorations.virtual_texts_for_line(decs, 0)
      assert length(vts_line0) == 1

      vts_line1 = Decorations.virtual_texts_for_line(decs, 1)
      assert vts_line1 == []

      vts_line2 = Decorations.virtual_texts_for_line(decs, 2)
      assert length(vts_line2) == 1
    end

    test "cache is invalidated on add" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_virtual_text(decs, {0, 0},
          segments: [{"first", Minga.UI.Face.new()}],
          placement: :eol
        )

      assert length(Decorations.virtual_texts_for_line(decs, 0)) == 1

      {_id, decs} =
        Decorations.add_virtual_text(decs, {0, 5},
          segments: [{"second", Minga.UI.Face.new()}],
          placement: :eol
        )

      assert length(Decorations.virtual_texts_for_line(decs, 0)) == 2
    end
  end
end

defmodule MingaEditor.RenderPipeline.InvalidationTest do
  @moduledoc """
  Tests for the first-class Stage 1 (Invalidation) output struct
  introduced as the foundation for the dirty-tracking work in #1431.
  """

  # async: false — `sanity_mode?/0` test mutates `MINGA_RENDER_SANITY` env var
  use ExUnit.Case, async: false

  alias MingaEditor.RenderPipeline.Invalidation
  alias MingaEditor.RenderPipeline.WindowDirty

  describe "Invalidation struct" do
    test "default is full_redraw with empty per-window and chrome maps" do
      inv = %Invalidation{}
      assert inv.full_redraw == true
      assert inv.windows == %{}
      assert MapSet.size(inv.chrome_regions) == 0
      assert inv.global_reasons == []
    end

    test "full_redraw/1 builds a struct with reasons attached" do
      inv = Invalidation.full_redraw([:resize, :theme_changed])
      assert inv.full_redraw == true
      assert inv.global_reasons == [:resize, :theme_changed]
      assert MapSet.size(inv.chrome_regions) == 0
    end

    test "sanity_mode?/0 reads the MINGA_RENDER_SANITY env var" do
      System.delete_env("MINGA_RENDER_SANITY")
      refute Invalidation.sanity_mode?()

      System.put_env("MINGA_RENDER_SANITY", "1")
      assert Invalidation.sanity_mode?()

      System.put_env("MINGA_RENDER_SANITY", "0")
      refute Invalidation.sanity_mode?()

      System.delete_env("MINGA_RENDER_SANITY")
    end
  end

  describe "WindowDirty struct" do
    test "clean/0 marks the window as nothing-to-do" do
      d = WindowDirty.clean()
      assert d.mode == :clean
      assert WindowDirty.clean?(d)
      refute WindowDirty.full?(d)
    end

    test "all/1 marks the whole window dirty with a reason" do
      d = WindowDirty.all(:buffer_edit)
      assert d.mode == :all
      assert d.reason == :buffer_edit
      assert WindowDirty.full?(d)
      refute WindowDirty.clean?(d)
    end

    test "rows/2 marks only listed lines dirty" do
      d = WindowDirty.rows([3, 7, 9], :viewport_scroll)
      assert d.mode == :rows
      assert d.reason == :viewport_scroll
      assert d.dirty_rows == %{3 => true, 7 => true, 9 => true}
      refute WindowDirty.clean?(d)
      refute WindowDirty.full?(d)
    end
  end
end

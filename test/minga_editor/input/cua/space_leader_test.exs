defmodule MingaEditor.Input.CUA.SpaceLeaderTest do
  use ExUnit.Case, async: true
  use Minga.Test.EditorCase

  describe "a fast space-leader chord in Vim Normal mode" do
    test "SPC f f typed as a chord opens find-file and leaves the buffer unchanged" do
      ctx = start_editor("hello world")

      send_gui_action(ctx, {:space_leader_chord, ?f, 0})
      send_keys_sync(ctx, "f")

      assert picker_open?(ctx)
      assert buffer_content(ctx) == "hello world"
      assert buffer_cursor(ctx) == {0, 0}
    end
  end
end

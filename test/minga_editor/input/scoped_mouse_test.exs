defmodule MingaEditor.Input.ScopedMouseTest do
  use ExUnit.Case, async: true

  @moduledoc false
  @moduletag :tmp_dir

  import Minga.Test.ScopedInputHelpers

  alias MingaEditor.Input.FileTreeHandler

  describe "handle_mouse" do
    test "routes or passes through by active surface", %{tmp_dir: tmp_dir} do
      for state <- [
            base_state(keymap_scope: :agent, agentic_active: true),
            make_tree_state(tmp_dir)
          ] do
        result = walk_surface_mouse(state, 5, 5, :left, 0, :press, 1)
        assert elem(result, 0) in [:handled, :passthrough]
      end

      state = base_state(keymap_scope: :editor)
      assert {:passthrough, _} = FileTreeHandler.handle_mouse(state, 5, 5, :left, 0, :press, 1)
    end
  end
end

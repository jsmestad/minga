defmodule Minga.Editor.RenderPipeline.EmitTest do
  @moduledoc """
  Tests for the Emit stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame}
  alias Minga.Editor.RenderPipeline.Emit

  import Minga.Editor.RenderPipeline.TestHelpers

  describe "emit/2" do
    test "converts frame to commands and sends to port_manager" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      assert :ok = Emit.emit(frame, state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert is_list(commands)
      assert Enum.all?(commands, &is_binary/1)
    end
  end
end

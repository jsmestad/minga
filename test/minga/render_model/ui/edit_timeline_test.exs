defmodule Minga.RenderModel.UI.EditTimelineTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.EditTimeline

  describe "%EditTimeline{}" do
    test "requires encoded and fingerprint" do
      model = %EditTimeline{encoded: <<>>, fingerprint: :hidden}

      assert model.encoded == <<>>
      assert model.fingerprint == :hidden
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(EditTimeline, %{})
      end
    end

    test "accepts visible state with integer fingerprint" do
      model = %EditTimeline{encoded: <<0x9B, 1>>, fingerprint: 42}

      assert model.fingerprint == 42
    end
  end
end

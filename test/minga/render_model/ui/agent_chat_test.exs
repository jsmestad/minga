defmodule Minga.RenderModel.UI.AgentChatTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.AgentChat

  describe "%AgentChat{}" do
    test "requires encoded and fingerprint" do
      model = %AgentChat{encoded: <<>>, fingerprint: :not_visible}

      assert model.encoded == <<>>
      assert model.fingerprint == :not_visible
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(AgentChat, %{})
      end
    end

    test "accepts visible state with integer fingerprint" do
      model = %AgentChat{encoded: <<0x78, 1>>, fingerprint: 12345}

      assert model.fingerprint == 12345
    end
  end
end

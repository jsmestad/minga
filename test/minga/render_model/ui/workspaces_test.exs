defmodule Minga.RenderModel.UI.WorkspacesTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Workspaces

  describe "%Workspaces{}" do
    test "defaults to nil encoded and suppressed fingerprint" do
      ws = %Workspaces{}

      assert ws.encoded == nil
      assert ws.fingerprint == :suppressed
    end

    test "accepts binary encoded and integer fingerprint" do
      ws = %Workspaces{encoded: <<0x98, 0, 5, "data">>, fingerprint: 12_345}

      assert ws.encoded == <<0x98, 0, 5, "data">>
      assert ws.fingerprint == 12_345
    end
  end
end

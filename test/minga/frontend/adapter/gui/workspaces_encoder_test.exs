defmodule Minga.Frontend.Adapter.GUI.WorkspacesEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WorkspacesEncoder
  alias Minga.RenderModel.UI.Workspaces

  @op_gui_workspaces Minga.Protocol.Opcodes.gui_workspaces()

  describe "encode/2" do
    test "returns nil when workspaces are suppressed (no tab bar)" do
      model = %Workspaces{encoded: nil, fingerprint: :suppressed}
      caches = Caches.new()

      {cmd, _caches} = WorkspacesEncoder.encode(model, caches)

      assert cmd == nil
    end

    test "encodes workspaces with payload" do
      model = %Workspaces{
        encoded: <<@op_gui_workspaces, 0::16, "workspace_data">>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd, _caches} = WorkspacesEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %Workspaces{
        encoded: <<@op_gui_workspaces, 5::16, "hello">>,
        fingerprint: 42
      }

      caches = Caches.new()

      {cmd1, caches} = WorkspacesEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = WorkspacesEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %Workspaces{
        encoded: <<@op_gui_workspaces, 3::16, "abc">>,
        fingerprint: 42
      }

      model2 = %Workspaces{
        encoded: <<@op_gui_workspaces, 5::16, "hello">>,
        fingerprint: 99999
      }

      caches = Caches.new()
      {_, caches} = WorkspacesEncoder.encode(model1, caches)
      {cmd2, _caches} = WorkspacesEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end

    test "updates cache fingerprint on encode" do
      model = %Workspaces{
        encoded: <<@op_gui_workspaces, 3::16, "abc">>,
        fingerprint: 42
      }

      caches = Caches.new()
      assert caches.last_workspaces_fp == nil

      {_cmd, caches} = WorkspacesEncoder.encode(model, caches)
      assert caches.last_workspaces_fp == 42
    end
  end
end

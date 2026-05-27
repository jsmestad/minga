defmodule Minga.Frontend.Adapter.GUI.FileTreeEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.FileTreeEncoder
  alias Minga.RenderModel.UI.FileTree

  describe "encode/2 - hidden/state fingerprints" do
    test "encodes hidden file tree on first call" do
      model = %FileTree{
        encoded: <<0x93, "hidden">>,
        fingerprint: {:no_tree, "/tmp/project"}
      }

      caches = Caches.new()

      {cmd, _caches} = FileTreeEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %FileTree{
        encoded: <<0x93, "hidden">>,
        fingerprint: {:no_tree, "/tmp/project"}
      }

      caches = Caches.new()

      {_cmd1, caches} = FileTreeEncoder.encode(model, caches)
      {cmd2, _caches} = FileTreeEncoder.encode(model, caches)

      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %FileTree{
        encoded: <<0x93, "hidden1">>,
        fingerprint: {:no_tree, "/tmp/first"}
      }

      model2 = %FileTree{
        encoded: <<0x93, "hidden2">>,
        fingerprint: {:no_tree, "/tmp/second"}
      }

      caches = Caches.new()
      {_, caches} = FileTreeEncoder.encode(model1, caches)
      {cmd2, _caches} = FileTreeEncoder.encode(model2, caches)

      assert cmd2 == model2.encoded
    end

    test "encodes file_tree_state fingerprint" do
      model = %FileTree{
        encoded: <<0x93, "loading">>,
        fingerprint: {:file_tree_state, "/project", 250, :loading}
      }

      caches = Caches.new()

      {cmd, caches} = FileTreeEncoder.encode(model, caches)

      assert cmd == model.encoded
      assert caches.last_file_tree_fp == {:file_tree_state, "/project", 250, :loading}
    end
  end

  describe "encode/2 - ready fingerprints (three-way comparison)" do
    test "encodes full tree on first call" do
      model = %FileTree{
        encoded: <<0x93, "full_tree">>,
        selection_encoded: <<0x94, "selection">>,
        fingerprint: {:ready, 111, 222}
      }

      caches = Caches.new()

      {cmd, _caches} = FileTreeEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil when nothing changed" do
      model = %FileTree{
        encoded: <<0x93, "full_tree">>,
        selection_encoded: <<0x94, "selection">>,
        fingerprint: {:ready, 111, 222}
      }

      caches = Caches.new()

      {_cmd1, caches} = FileTreeEncoder.encode(model, caches)
      {cmd2, _caches} = FileTreeEncoder.encode(model, caches)

      assert cmd2 == nil
    end

    test "sends selection-only command when only selection changes" do
      model1 = %FileTree{
        encoded: <<0x93, "full_tree">>,
        selection_encoded: <<0x94, "selection1">>,
        fingerprint: {:ready, 111, 222}
      }

      model2 = %FileTree{
        encoded: <<0x93, "full_tree">>,
        selection_encoded: <<0x94, "selection2">>,
        fingerprint: {:ready, 111, 333}
      }

      caches = Caches.new()
      {_, caches} = FileTreeEncoder.encode(model1, caches)
      {cmd2, caches} = FileTreeEncoder.encode(model2, caches)

      assert cmd2 == <<0x94, "selection2">>
      assert caches.last_file_tree_fp == {:ready, 111, 333}
    end

    test "sends full tree when structural fingerprint changes" do
      model1 = %FileTree{
        encoded: <<0x93, "tree_v1">>,
        selection_encoded: <<0x94, "sel_v1">>,
        fingerprint: {:ready, 111, 222}
      }

      model2 = %FileTree{
        encoded: <<0x93, "tree_v2">>,
        selection_encoded: <<0x94, "sel_v2">>,
        fingerprint: {:ready, 999, 222}
      }

      caches = Caches.new()
      {_, caches} = FileTreeEncoder.encode(model1, caches)
      {cmd2, _caches} = FileTreeEncoder.encode(model2, caches)

      assert cmd2 == <<0x93, "tree_v2">>
    end

    test "transition from hidden to ready sends full tree" do
      hidden = %FileTree{
        encoded: <<0x93, "hidden">>,
        fingerprint: {:no_tree, "/project"}
      }

      ready = %FileTree{
        encoded: <<0x93, "ready_tree">>,
        selection_encoded: <<0x94, "sel">>,
        fingerprint: {:ready, 111, 222}
      }

      caches = Caches.new()
      {_, caches} = FileTreeEncoder.encode(hidden, caches)
      {cmd2, _caches} = FileTreeEncoder.encode(ready, caches)

      assert cmd2 == <<0x93, "ready_tree">>
    end

    test "transition from ready to hidden sends hidden command" do
      ready = %FileTree{
        encoded: <<0x93, "ready_tree">>,
        selection_encoded: <<0x94, "sel">>,
        fingerprint: {:ready, 111, 222}
      }

      hidden = %FileTree{
        encoded: <<0x93, "hidden">>,
        fingerprint: {:no_tree, "/project"}
      }

      caches = Caches.new()
      {_, caches} = FileTreeEncoder.encode(ready, caches)
      {cmd2, _caches} = FileTreeEncoder.encode(hidden, caches)

      assert cmd2 == <<0x93, "hidden">>
    end
  end
end

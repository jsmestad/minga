defmodule Minga.SystemObserver.TreeNodeTest do
  use ExUnit.Case, async: true

  alias Minga.SystemObserver.ProcessSnapshot
  alias Minga.SystemObserver.TreeNode

  describe "build_tree/1" do
    test "returns nil for an empty snapshot map" do
      assert TreeNode.build_tree(%{}) == nil
    end

    test "builds a hierarchy from flat process snapshots" do
      root_pid = self()
      child_pid = spawn_idle_process()
      grandchild_pid = spawn_idle_process()
      sibling_pid = spawn_idle_process()

      snapshots = %{
        root_pid =>
          snapshot(parent_pid: nil, child_type: :supervisor, process_class: :supervisor),
        child_pid =>
          snapshot(parent_pid: root_pid, child_type: :supervisor, process_class: :supervisor),
        grandchild_pid =>
          snapshot(parent_pid: child_pid, child_type: :worker, process_class: :buffer),
        sibling_pid => snapshot(parent_pid: root_pid, child_type: :worker, process_class: :worker)
      }

      tree = TreeNode.build_tree(snapshots)

      assert %TreeNode{pid: ^root_pid, depth: 0, children: root_children} = tree
      assert Enum.map(root_children, & &1.depth) == [1, 1]
      assert Enum.any?(root_children, fn node -> node.pid == sibling_pid end)

      child_node = Enum.find(root_children, fn node -> node.pid == child_pid end)
      assert %TreeNode{children: [%TreeNode{pid: ^grandchild_pid, depth: 2}]} = child_node
    end

    test "ignores orphaned processes that cannot be attached to the root" do
      root_pid = self()
      orphan_parent_pid = spawn_idle_process()
      orphan_pid = spawn_idle_process()

      snapshots = %{
        root_pid =>
          snapshot(parent_pid: nil, child_type: :supervisor, process_class: :supervisor),
        orphan_pid =>
          snapshot(parent_pid: orphan_parent_pid, child_type: :worker, process_class: :worker)
      }

      tree = TreeNode.build_tree(snapshots)

      assert %TreeNode{pid: ^root_pid, children: []} = tree
    end

    test "flattens a tree in pre-order for protocol encoding and hit lookup" do
      root_pid = self()
      child_pid = spawn_idle_process()
      grandchild_pid = spawn_idle_process()

      snapshots = %{
        root_pid =>
          snapshot(parent_pid: nil, child_type: :supervisor, process_class: :supervisor),
        child_pid =>
          snapshot(parent_pid: root_pid, child_type: :supervisor, process_class: :supervisor),
        grandchild_pid =>
          snapshot(parent_pid: child_pid, child_type: :worker, process_class: :worker)
      }

      assert [
               %TreeNode{pid: ^root_pid},
               %TreeNode{pid: ^child_pid},
               %TreeNode{pid: ^grandchild_pid}
             ] =
               snapshots |> TreeNode.build_tree() |> TreeNode.flatten()
    end
  end

  defp spawn_idle_process do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp snapshot(attrs) do
    attrs = Keyword.merge([parent_pid: nil, child_type: :worker, process_class: :worker], attrs)

    %ProcessSnapshot{
      memory: 1,
      message_queue_len: 0,
      reductions: 1,
      current_function: nil,
      registered_name: nil,
      parent_pid: Keyword.fetch!(attrs, :parent_pid),
      child_type: Keyword.fetch!(attrs, :child_type),
      process_class: Keyword.fetch!(attrs, :process_class)
    }
  end
end

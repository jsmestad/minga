defmodule MingaEditor.Input.ObservatoryTest do
  use ExUnit.Case, async: true

  alias Minga.SystemObserver.ProcessSnapshot
  alias Minga.SystemObserver.TreeNode
  alias MingaEditor.Input.Observatory
  alias MingaEditor.Shell.Traditional.State, as: ShellState

  describe "inspect_process/2" do
    test "formats GenServer state for a selected process" do
      {:ok, pid} = Agent.start_link(fn -> %{messages: [:one, :two], files_touched: %{}} end)
      state = state_with_tree(pid, :agent_session)
      pid_string = :erlang.pid_to_list(pid) |> to_string()

      state = Observatory.inspect_process(state, pid_string)

      assert %{visible: true, title: title, lines: lines} =
               state.shell_state.observatory_inspection

      assert title == "Process #{pid_string}"
      assert "Class: agent session" in lines
      assert "Conversation entries: 2" in lines
    end

    test "reports invalid PID strings" do
      state = Observatory.inspect_process(base_state(), "not-a-pid")

      assert %{visible: true, title: "Process not-a-pid", lines: ["Invalid BEAM PID"]} =
               state.shell_state.observatory_inspection
    end

    test "empty PID dismisses the inspection popup" do
      state = Observatory.inspect_process(base_state(), "not-a-pid")
      state = Observatory.inspect_process(state, "")

      assert state.shell_state.observatory_inspection == nil
    end

    test "falls back to process info when GenServer state is unavailable" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      state = Observatory.inspect_process(base_state(), :erlang.pid_to_list(pid) |> to_string())

      assert %{visible: true, lines: lines} = state.shell_state.observatory_inspection
      assert Enum.any?(lines, &String.starts_with?(&1, "GenServer state unavailable:"))
      assert "Process info:" in lines
    end
  end

  defp base_state do
    %{shell_state: %ShellState{}}
  end

  defp state_with_tree(pid, process_class) do
    tree = %TreeNode{pid: pid, snapshot: snapshot(process_class), children: [], depth: 0}
    %{shell_state: %ShellState{observatory_data: %{tree: tree}}}
  end

  defp snapshot(process_class) do
    %ProcessSnapshot{
      memory: 1,
      message_queue_len: 0,
      reductions: 1,
      current_function: nil,
      registered_name: nil,
      parent_pid: nil,
      child_type: :worker,
      process_class: process_class
    }
  end
end

defmodule MingaAgent.Tools.ShellExecutionGuardTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.Test.BlockingProcessBackend
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Executor
  alias MingaAgent.Tools

  @moduletag :tmp_dir

  test "the shell timeout covers backend execution", %{tmp_dir: dir} do
    {:ok, project_view} = RecordingBackend.create(dir, parent: self(), working_dir: dir)

    context =
      Context.new(
        project_root: dir,
        project_view: project_view,
        metadata: %{process_backend: BlockingProcessBackend}
      )

    assert_shell_times_out(context)
  end

  test "the shell timeout covers workspace preparation", %{tmp_dir: dir} do
    {:ok, project_view} =
      RecordingBackend.create(dir, parent: self(), working_dir: dir, block_prepare?: true)

    context = Context.new(project_root: dir, project_view: project_view)

    assert_shell_times_out(context)
    assert_received {:project_view_call, :prepare_working_dir}
  end

  @spec assert_shell_times_out(Context.t()) :: :ok
  defp assert_shell_times_out(context) do
    spec = Enum.find(Tools.specs(), &(&1.name == "shell"))

    assert {:error, "command timed out"} =
             Executor.execute_approved(
               spec,
               %{"command" => "blocked", "timeout" => 1},
               config: %AgentConfig{},
               tool_context: context
             )

    :ok
  end
end

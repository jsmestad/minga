defmodule MingaAgent.Test.RetainedContextFixture do
  @moduledoc false

  alias MingaAgent.Tool.Context

  @spec new(String.t(), String.t()) :: Context.t()
  def new(project_root, call_id) when is_binary(project_root) and is_binary(call_id) do
    root =
      Path.join(System.tmp_dir!(), "minga-test-artifacts-#{System.unique_integer([:positive])}")

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    quota =
      ExUnit.Callbacks.start_supervised!(
        {MingaAgent.ArtifactQuota, root: root, name: nil},
        id: {__MODULE__, root, :quota}
      )

    store =
      ExUnit.Callbacks.start_supervised!(
        {MingaAgent.ArtifactStore, root: root, quota: quota, session_id: "test-record"},
        id: {__MODULE__, root, :store}
      )

    Context.for_tool_call(
      Context.new(project_root: project_root),
      store,
      "test-checkpoint",
      call_id
    )
  end
end

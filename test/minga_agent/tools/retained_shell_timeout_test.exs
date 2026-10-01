defmodule MingaAgent.Tools.RetainedShellTimeoutTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tools

  @moduletag :tmp_dir

  defmodule TimeoutBackend do
    @moduledoc false
    @behaviour MingaAgent.Tools.ProcessBackend

    @impl true
    def find(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    def grep(_pattern, _path, _opts, _exec_opts), do: {:error, "unsupported"}

    @impl true
    def shell(_command, _cwd, _timeout_secs, _opts) do
      {:error, {:incomplete, :timeout, "durable partial output"}}
    end
  end

  test "the canonical shell timeout becomes an incomplete retained Output", %{tmp_dir: root} do
    quota =
      start_supervised!(
        Supervisor.child_spec({ArtifactQuota, root: root},
          id: {:timeout_quota, make_ref()},
          restart: :temporary
        )
      )

    store =
      start_supervised!(
        Supervisor.child_spec(
          {ArtifactStore, root: root, quota: quota, session_id: "timeout-session"},
          id: {:timeout_store, make_ref()},
          restart: :temporary
        )
      )

    delivery_key = {:delivery, "checkpoint-1", "shell-call"}

    context =
      Context.new(
        project_root: root,
        artifact_store: store,
        capture_key: delivery_key,
        metadata: %{process_backend: TimeoutBackend}
      )

    shell = Enum.find(Tools.all(), &(&1.name == "shell"))
    callback = MingaAgent.Tool.Spec.build_callback(shell, context)

    assert {:error,
            %Output{
              capture: {:incomplete, :timeout},
              view: "durable partial output",
              reference: reference,
              selection: selection
            }} = callback.(%{"command" => "ignored", "timeout" => 1})

    assert {:ok, %{bytes: "durable partial output", capture: {:incomplete, :timeout}}} =
             ArtifactStore.fetch(store, reference, selection)

    assert {:ok, %{reference: ^reference, capture: {:incomplete, :timeout}}} =
             ArtifactStore.lookup_delivery(store, delivery_key)
  end
end

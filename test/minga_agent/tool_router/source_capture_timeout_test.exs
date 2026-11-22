defmodule MingaAgent.ToolRouter.SourceCaptureTimeoutTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ToolRouter.Context
  alias MingaAgent.ToolRouter.SourceCapture

  @moduletag :tmp_dir

  test "a disk read whose capture commit stalls reports storage_timeout and leaves nothing retained",
       %{tmp_dir: root} do
    path = Path.join(root, "slow.txt")
    File.write!(path, "α one\n  two\nthree")
    test_pid = self()

    # Stands in for an fsync that outlives the capture bound, after quota admission.
    stalled_write = fn ->
      send(test_pid, {:stalled, self()})

      receive do
        :release -> :ok
      end
    end

    artifacts = Path.join(root, "artifacts")
    quota = start_supervised!({ArtifactQuota, root: artifacts, name: nil})

    store =
      start_supervised!(
        {ArtifactStore,
         root: artifacts,
         quota: quota,
         session_id: "slow-read",
         call_timeout: 50,
         fault_injector: %{before_blob_write: stalled_write}}
      )

    baseline = ArtifactQuota.usage(quota)
    delivery_key = {:delivery, "slow-checkpoint", "read"}

    assert {:error, :storage_timeout} =
             SourceCapture.capture(%Context{}, path, store, delivery_key, [])

    assert_receive {:stalled, ^store}
    send(store, :release)

    # The store completes the stalled append, then cancels the abandoned capture.
    :sys.get_state(store)

    assert {:error, :unknown_delivery} = ArtifactStore.lookup_delivery(store, delivery_key)
    assert ArtifactQuota.usage(quota) == baseline
  end
end

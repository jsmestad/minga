defmodule MingaAgent.ArtifactQuota.LedgerTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota.Ledger
  alias MingaAgent.ArtifactStore.Limits
  alias MingaAgent.Config

  @moduletag :tmp_dir

  test "quota mutations reject zero changed rows before checkpointing", %{tmp_dir: dir} do
    assert {:ok, db} = Ledger.open(Path.join([dir, "artifacts", "quota.sqlite3"]))
    on_exit(fn -> Ledger.close(db) end)

    assert {:ok, limits} = Limits.new(%{}, Config.artifact_limits())
    assert {:ok, :inserted} = Ledger.insert_namespace(db, "namespace", limits)
    assert {:ok, :reserved} = Ledger.reserve(db, "namespace", 10, 1, 1, 1)
    assert {:ok, original} = Ledger.get(db, "namespace")

    opts = [before_checkpoint: fn -> flunk("rejected mutations must not checkpoint") end]

    assert {:error, :invalid_quota_release} = Ledger.release(db, "namespace", 0, 2, 1, opts)
    assert {:error, :invalid_quota_release} = Ledger.cancel_capture(db, "namespace", 0, 2, opts)
    assert {:error, :invalid_open_capture_release} = Ledger.finish_capture(db, "missing", opts)
    assert {:error, :namespace_not_empty} = Ledger.delete_namespace(db, "namespace", opts)
    assert {:error, :quota_row_not_found} = Ledger.reserve(db, "missing", 0, 0, 0, 0, opts)
    assert {:ok, ^original} = Ledger.get(db, "namespace")

    assert {:error, {:checkpoint_failed, :busy}, {:committed, :finished}} =
             Ledger.finish_capture(db, "namespace", before_checkpoint: fn -> {:error, :busy} end)

    assert {:ok, %{open_captures: 0}} = Ledger.get(db, "namespace")
    assert {:error, :invalid_open_capture_release} = Ledger.finish_capture(db, "namespace", opts)
  end
end

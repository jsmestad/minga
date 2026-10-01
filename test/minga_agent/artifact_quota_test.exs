defmodule MingaAgent.ArtifactQuotaTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.ArtifactStore.Limits
  alias MingaAgent.Tool.Output.Reference

  @moduletag :tmp_dir

  test "admits before writes and reports session bytes, artifact counts, and open counts", %{
    tmp_dir: root
  } do
    envelope = Limits.sqlite_envelope_bytes()

    byte_limits = [
      root_bytes: envelope * 3,
      session_bytes: envelope + 80,
      capture_bytes: 64,
      append_bytes: 64,
      image_bytes: 64
    ]

    quota = start_quota(root, {:byte_quota, make_ref()}, limits: byte_limits)
    store = start_store(root, quota, "byte-session", {:byte_store, make_ref()}, limits: byte_limits)
    spec = capture_spec("byte-limit", expected_bytes: 64)
    assert {:error, :session_disk_quota} = ArtifactStore.begin(store, spec)

    count_limits = [session_artifacts: 2, session_open_captures: 1]
    count_root = Path.join(root, "counts")
    count_quota = start_quota(count_root, {:count_quota, make_ref()}, limits: count_limits)

    count_store =
      start_store(
        count_root,
        count_quota,
        "count-session",
        {:count_store, make_ref()},
        limits: count_limits
      )

    first = begin_capture(count_store, "first")
    assert {:error, :session_open_capture_limit} =
             ArtifactStore.begin(count_store, capture_spec("second-open"))

    assert {:ok, %{reference: _reference}} = ArtifactStore.finish(count_store, first, :complete)
    second = begin_capture(count_store, "second")
    assert {:ok, %{reference: _reference}} = ArtifactStore.finish(count_store, second, :complete)
    assert {:error, :session_artifact_limit} =
             ArtifactStore.begin(count_store, capture_spec("third-artifact"))
  end

  test "quota actor reconstructs conservative reservations on the first later admission", %{
    tmp_dir: root
  } do
    quota_id = {:quota, make_ref()}
    store_id = {:store, make_ref()}
    quota = start_quota(root, quota_id)
    store = start_store(root, quota, "ledger-session", store_id)
    capture = begin_capture(store, "ledger-call")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "ledger bytes")
    before = ArtifactQuota.usage(quota)

    :ok = stop_supervised(store_id)
    :ok = stop_supervised(quota_id)

    restarted = start_quota(root, quota_id)
    assert %{bytes: 0, artifacts: 0, open_captures: 0, namespaces: 0} =
             ArtifactQuota.usage(restarted)

    namespace = Reference.namespace("ledger-session")
    assert {:ok, _limits} = ArtifactQuota.register_namespace(restarted, root, namespace)
    after_admission = ArtifactQuota.usage(restarted)

    assert after_admission.bytes == before.bytes
    assert after_admission.items == before.items
    assert after_admission.artifacts == 1
    assert after_admission.open_captures == 1
    assert after_admission.namespaces == 1
  end
  test "root aggregate and item reservations refuse before append writes", %{tmp_dir: root} do
    envelope = Limits.sqlite_envelope_bytes()

    limits = [
      root_bytes: envelope * 3 + 100,
      session_bytes: envelope + 100,
      capture_bytes: 64,
      append_bytes: 64,
      image_bytes: 64,
      root_items: 4,
      session_items: 2,
      capture_items: 2
    ]

    quota = start_quota(root, {:quota, make_ref()}, limits: limits)
    first = start_store(root, quota, "root-one", {:store_one, make_ref()}, limits: limits)
    first_spec = capture_spec("root-first", expected_bytes: 64)
    assert {:ok, _capture} = ArtifactStore.begin(first, first_spec)

    second = start_store(root, quota, "root-two", {:store_two, make_ref()}, limits: limits)
    assert {:error, :root_disk_quota} =
             ArtifactStore.begin(second, capture_spec("root-second"))

    item_root = Path.join(root, "items")
    item_quota = start_quota(item_root, {:item_quota, make_ref()}, limits: limits)

    item_store =
      start_store(
        item_root,
        item_quota,
        "item-session",
        {:item_store, make_ref()},
        limits: limits
      )

    assert {:ok, item_spec} =
             CaptureSpec.new(
               media_type: "text/plain",
               mode: :items,
               owner_pid: self(),
               delivery_key: {:delivery, "checkpoint-1", "item-limit"}
             )

    assert {:ok, item_capture} = ArtifactStore.begin(item_store, item_spec)

    assert {:error, :session_item_quota} =
             ArtifactStore.append(item_store, item_capture, "a\\nb\\nc\\n",
               item_ends: [2, 4, 6]
             )

    assert {:error, {:capture_incomplete, :session_item_quota}} =
             ArtifactStore.finish(item_store, item_capture, :complete)
  end


  test "owner limits cannot increase root policy and pin set count is finite", %{tmp_dir: root} do
    root_limits = [capture_bytes: 1024, append_bytes: 1024, image_bytes: 1024, session_pin_sets: 1]
    quota = start_quota(root, {:quota, make_ref()}, limits: root_limits)

    assert {:error, {:invalid_limits, _child}} =
             start_supervised(
               {ArtifactStore,
                root: root,
                quota: quota,
                session_id: "upward-session",
                limits: [capture_bytes: 2048, append_bytes: 1024, image_bytes: 1024]},
               id: {:upward_store, make_ref()}
             )

    assert {:error, {:invalid_artifact_root, _child}} =
             start_supervised(
               {ArtifactStore,
                root: Path.join(root, "different-root"),
                quota: quota,
                session_id: "wrong-root-session"},
               id: {:wrong_root_store, make_ref()}
             )

    store =
      start_store(root, quota, "pin-limit-session", {:store, make_ref()}, limits: root_limits)

    capture = begin_capture(store, "pin-limit-call")
    assert {:ok, %{reference: reference}} = ArtifactStore.finish(store, capture, :complete)

    assert :ok =
             ArtifactStore.pin(store, {:snapshot, "one"}, [reference],
               transfer_delivery: true
             )

    assert {:error, :pin_set_limit} =
             ArtifactStore.pin(store, {:snapshot, "two"}, [reference])
  end

  test "cold quota actors take the lock only after valid same-root admission and can retry later", %{
    tmp_dir: root
  } do
    first = start_quota(root, {:first_quota, make_ref()})
    second = start_quota(root, {:second_quota, make_ref()})
    first_namespace = Reference.namespace("first-record")
    second_namespace = Reference.namespace("second-record")

    assert %{bytes: 0, namespaces: 0} = ArtifactQuota.usage(first)
    assert %{bytes: 0, namespaces: 0} = ArtifactQuota.usage(second)
    assert {:error, :invalid_namespace} = ArtifactQuota.register_namespace(first, root, "not-a-hash")

    assert {:error, :invalid_artifact_root} =
             ArtifactQuota.register_namespace(first, Path.join(root, "foreign"), first_namespace)

    assert {:ok, _limits} = ArtifactQuota.register_namespace(second, root, second_namespace)
    assert {:error, :artifact_root_in_use} =
             ArtifactQuota.register_namespace(first, root, first_namespace)

    assert %{bytes: 0, namespaces: 0} = ArtifactQuota.usage(first)
    GenServer.stop(second)

    assert {:ok, _limits} = ArtifactQuota.register_namespace(first, root, first_namespace)
    assert %{namespaces: 2} = ArtifactQuota.usage(first)
  end

  test "cold reserve and release operations fail without opening storage", %{tmp_dir: root} do
    quota = start_quota(root, {:quota, make_ref()})
    namespace = Reference.namespace("cold-record")

    assert {:error, :storage_unavailable} =
             ArtifactQuota.reserve_capture(quota, namespace, 32)

    assert {:error, :storage_unavailable} =
             ArtifactQuota.release_artifact(quota, namespace, 32, 0)

    assert %{bytes: 0, limit_bytes: limit} = ArtifactQuota.usage(quota)
    assert limit == MingaAgent.Config.artifact_limits().root_bytes
    assert {:error, :enoent} = File.lstat(Path.join(root, "artifact_quota.sqlite3"))
  end

  test "failed WAL checkpoint blocks writes while retaining committed conservative charge", %{
    tmp_dir: root
  } do
    quota =
      start_quota(root, {:quota, make_ref()},
        fault_injector: %{before_quota_checkpoint: {:error, :checkpoint_busy}}
      )

    namespace = Reference.namespace("checkpoint-session")

    assert {:error, :storage_unavailable} =
             ArtifactQuota.register_namespace(quota, root, namespace)

    usage = ArtifactQuota.usage(quota)
    assert usage.namespaces == 1
    assert usage.bytes == Limits.sqlite_envelope_bytes() * 2

    assert {:error, :storage_unavailable} =
             ArtifactQuota.register_namespace(
               quota,
               root,
               Reference.namespace("blocked-session")
             )
  end

  test "artifact directories and every materialized owned file remain private and regular", %{
    tmp_dir: root
  } do
    quota = start_quota(root, {:quota, make_ref()})
    store = start_store(root, quota, "private-session", {:store, make_ref()})
    capture = begin_capture(store, "private-call")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "private")
    assert {:ok, %{reference: reference}} = ArtifactStore.finish(store, capture, :complete)
    {:ok, namespace, id} = MingaAgent.Tool.Output.Reference.parse(reference.token)
    namespace_dir = Path.join([root, "namespaces", namespace])

    assert_private_directory(root)
    assert_private_directory(Path.join(root, "namespaces"))
    assert_private_directory(namespace_dir)

    paths = [
      Path.join(root, "artifact_quota.sqlite3"),
      Path.join(namespace_dir, "artifacts.sqlite3"),
      Path.join(namespace_dir, id <> ".blob"),
      Path.join(namespace_dir, id <> ".index")
    ]

    Enum.each(paths, &assert_private_regular/1)

    Enum.each(
      [
        Path.join(root, "artifact_quota.sqlite3-wal"),
        Path.join(root, "artifact_quota.sqlite3-shm"),
        Path.join(namespace_dir, "artifacts.sqlite3-wal"),
        Path.join(namespace_dir, "artifacts.sqlite3-shm")
      ],
      fn sidecar ->
        case File.lstat(sidecar) do
          {:ok, _stat} -> assert_private_regular(sidecar)
          {:error, :enoent} -> :ok
        end
      end
    )
  end

  defp start_quota(root, id, opts \\ []) do
    child =
      Supervisor.child_spec(
        {ArtifactQuota, Keyword.merge([root: root], opts)},
        id: id,
        restart: :temporary
      )

    start_supervised!(child)
  end

  defp start_store(root, quota, session_id, id, opts \\ []) do
    child =
      Supervisor.child_spec(
        {ArtifactStore,
         Keyword.merge([root: root, quota: quota, session_id: session_id], opts)},
        id: id,
        restart: :temporary
      )

    start_supervised!(child)
  end

  defp begin_capture(store, call_id) do
    assert {:ok, capture} = ArtifactStore.begin(store, capture_spec(call_id))
    capture
  end

  defp capture_spec(call_id, opts \\ []) do
    attrs =
      Keyword.merge(
        [
          media_type: "text/plain",
          mode: :bytes,
          owner_pid: self(),
          delivery_key: {:delivery, "checkpoint-1", call_id}
        ],
        opts
      )

    assert {:ok, spec} = CaptureSpec.new(attrs)
    spec
  end

  defp assert_private_directory(path) do
    assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(path)
    assert band(mode, 0o777) == 0o700
  end

  defp assert_private_regular(path) do
    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(path)
    assert band(mode, 0o777) == 0o600
  end
end

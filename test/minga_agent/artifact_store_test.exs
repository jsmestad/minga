defmodule MingaAgent.ArtifactStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStorage.SQLite
  alias MingaAgent.ArtifactStore.Limits
  alias MingaAgent.ArtifactStore.Paths
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.DraftAttachment
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference

  @moduletag :tmp_dir

  test "a composer selection reads its exact retained text only with the captured revision and owner",
       %{tmp_dir: root} do
    {quota, store} = start_pair(root, "composer-selection")
    other = start_store(root, quota, "other-composer", {:store, make_ref()})
    text = "selected e\u0301 and 日本語\nwith final newline\n"

    assert {:ok, {:selection, source, label, _revision, captured} = attachment, _pin} =
             DraftAttachment.capture_text(
               store,
               {:selection, "test.ex", "test.ex selection", text}
             )

    assert {:ok, ^text} = DraftAttachment.read_text(store, attachment)
    assert {:error, :unauthorized} = DraftAttachment.read_text(other, attachment)

    assert {:error, :invalid_attachment_snapshot} =
             DraftAttachment.read_text(
               store,
               {:selection, source, label, "other-revision", captured}
             )
  end

  test "a committed binary creation retains exact bytes without inventing a baseline", %{
    tmp_dir: root
  } do
    alias Minga.Buffer.FileMutation.Receipt
    alias MingaAgent.Session.FileChange
    alias MingaAgent.Tool.FileMutationResult

    {_quota, store} = start_pair(root, "file-change")
    bytes = <<0, 255, 10>>

    mutation =
      FileMutationResult.new(
        "/fixture.bin",
        Receipt.committed({:error, :enoent}, bytes),
        "created"
      )

    change = FileChange.capture(store, {"request", "checkpoint", "call"}, mutation)

    assert {:ok,
            %FileChange{
              identity: {"request", "checkpoint", "call"},
              before: :absent,
              after: reference
            }} =
             change |> FileChange.encode() |> FileChange.decode()

    candidate = {:snapshot, "candidate"}
    assert :ok = ArtifactStore.pin(store, candidate, [reference])
    assert :ok = FileChange.release_delivery(store, change)

    assert {:ok, range} = Range.new(:full, :bytes, 0, 3, 3)
    assert {:ok, %{bytes: ^bytes}} = ArtifactStore.fetch(store, reference, range)

    assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)
    assert :ok = ArtifactStore.release(store, candidate)
    assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(store)
  end

  test "cumulative attribution refuses an intervening edit", %{tmp_dir: root} do
    alias Minga.Buffer.FileMutation.Receipt
    alias MingaAgent.Session.FileChange
    alias MingaAgent.Tool.FileMutationResult

    {_quota, store} = start_pair(root, "cumulative-lineage")
    path = "/file"

    capture = fn call, before_bytes, after_bytes ->
      mutation =
        FileMutationResult.new(path, Receipt.committed({:ok, before_bytes}, after_bytes), "")

      FileChange.capture(store, {"request", "checkpoint", call}, mutation)
    end

    first = capture.("first", "original", "first edit")
    second = capture.("second", "first edit", "second edit")
    changed = capture.("third", "human edit", "third edit")

    assert {:ok, before_side, after_side} = FileChange.cumulative_sides([second, first], path)
    assert {:ok, "original"} = FileChange.read_side(store, before_side)
    assert {:ok, "second edit"} = FileChange.read_side(store, after_side)

    assert {:error, :discontinuous_file_change} =
             FileChange.cumulative_sides([changed, second, first], path)

    deletion = capture.("delete", "second edit", :deleted)
    assert {:ok, baseline, :absent} = FileChange.cumulative_sides([deletion, second, first], path)
    assert {:ok, "original"} = FileChange.read_side(store, baseline)
    assert {:ok, :absent} = FileChange.read_side(store, :absent)
  end

  test "checkpoint recovery reclaims snapshots abandoned by a dead worker", %{tmp_dir: root} do
    alias Minga.Buffer.FileMutation.Receipt
    alias MingaAgent.Session.FileChange
    alias MingaAgent.Tool.FileMutationResult

    {_quota, store} = start_pair(root, "abandoned-change")
    identity = {"request", "checkpoint", "call"}
    mutation = FileMutationResult.new("/file", Receipt.committed({:error, :enoent}, "new"), "")
    owner = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        send(owner, {:captured, FileChange.capture(store, identity, mutation)})
      end)

    assert_receive {:captured, %FileChange{after: %Reference{}}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)
    assert :ok = FileChange.reconcile_delivery(store, identity)
    assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(store)
  end

  test "an interrupted file capture does not pin the discarded partial snapshot", %{tmp_dir: root} do
    alias Minga.Buffer.FileMutation.Receipt
    alias MingaAgent.Session.FileChange
    alias MingaAgent.Tool.FileMutationResult

    writes = :atomics.new(1, [])

    injector = fn
      :before_blob_write ->
        if :atomics.add_get(writes, 1, 1) == 2, do: {:error, :enospc}, else: :ok

      _point ->
        :ok
    end

    {_quota, store} =
      start_pair_with_store_opts(root, "interrupted-change", fault_injector: injector)

    bytes = :binary.copy("a", 131_072)
    mutation = FileMutationResult.new("/large", Receipt.committed({:error, :enoent}, bytes), "")

    assert %FileChange{before: :absent, after: :unavailable} =
             FileChange.capture(store, {"request", "checkpoint", "call"}, mutation)

    assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(store)
  end

  test "failed optional finalization does not leave an artifact after reopen", %{tmp_dir: root} do
    alias Minga.Buffer.FileMutation.Receipt
    alias MingaAgent.Session.FileChange
    alias MingaAgent.Tool.FileMutationResult

    injector = fn
      :before_blob_rename -> {:error, :enospc}
      _point -> :ok
    end

    quota = start_quota(root, {:quota, make_ref()})
    store_id = {:store, make_ref()}
    store = start_store(root, quota, "failed-finish", store_id, fault_injector: injector)
    mutation = FileMutationResult.new("/file", Receipt.committed({:error, :enoent}, "new"), "")

    assert %FileChange{after: :unavailable} =
             FileChange.capture(store, {"request", "checkpoint", "call"}, mutation)

    assert :ok = stop_supervised(store_id)
    _reopened = start_store(root, quota, "failed-finish", store_id)
    assert ArtifactQuota.usage(quota).artifacts == 0
  end

  test "an optional file snapshot leaves the last slot for a tool result", %{tmp_dir: root} do
    alias Minga.Buffer.FileMutation.Receipt
    alias MingaAgent.Session.FileChange
    alias MingaAgent.Tool.FileMutationResult
    alias MingaAgent.Tools.OutputCapture

    {_quota, store} =
      start_pair_with_store_opts(root, "limited-changes", limits: [session_artifacts: 1])

    mutation = FileMutationResult.new("/file", Receipt.committed({:error, :enoent}, "new"), "")

    assert %FileChange{before: :absent, after: :unavailable} =
             FileChange.capture(store, {"request", "checkpoint", "write"}, mutation)

    assert {:ok, %{capture: :complete, reference: reference}} =
             OutputCapture.bytes(store, {:delivery, "next-checkpoint", "result"}, "done", [])

    assert {:ok, %{bytes: "done"}} = ArtifactStore.fetch(store, reference, byte_range(4))
  end

  test "an open optional snapshot leaves an open slot for a tool result", %{tmp_dir: root} do
    {_quota, store} =
      start_pair_with_store_opts(root, "open-capture-headroom",
        limits: [session_open_captures: 2]
      )

    optional_capture = fn call ->
      {:ok, spec} =
        CaptureSpec.new(
          media_type: "application/octet-stream",
          mode: :bytes,
          expected_bytes: 3,
          optional?: true,
          owner_pid: self(),
          delivery_key: {:delivery, "optional", call}
        )

      ArtifactStore.begin(store, spec)
    end

    assert {:ok, _open} = optional_capture.("first")
    assert {:error, :session_open_capture_limit} = optional_capture.("second")
    required = begin_capture(store, "required", :bytes, "text/plain")
    assert {:ok, _progress} = ArtifactStore.append(store, required, "done")
    assert {:ok, %{reference: reference}} = ArtifactStore.finish(store, required, :complete)
    assert {:ok, %{bytes: "done"}} = ArtifactStore.fetch(store, reference, byte_range(4))
  end

  test "fetches exact binary, Unicode byte slices, and indexed item pages", %{tmp_dir: root} do
    {_quota, store} = start_pair(root, "exact-session")
    bytes = <<0, 255, "αβ"::binary, 10>>
    expected_bytes = byte_size(bytes)
    capture = begin_capture(store, "bytes-call", :bytes, "application/octet-stream")

    assert {:ok, %{bytes: ^expected_bytes, items: 0}} =
             ArtifactStore.append(store, capture, bytes)

    assert {:ok, %{reference: byte_ref, capture: :complete}} =
             ArtifactStore.finish(store, capture, :complete)

    {:ok, byte_range} = Range.new(:page, :bytes, 1, byte_size(bytes) - 2, :unknown)

    assert {:ok, %{bytes: expected, selection: %{total: total}}} =
             ArtifactStore.fetch(store, byte_ref, byte_range)

    assert expected == binary_part(bytes, 1, byte_size(bytes) - 2)
    assert total == byte_size(bytes)

    item_bytes = "α\nβ\nγ\n"
    items = begin_capture(store, "items-call", :items, "text/plain")

    assert {:ok, %{bytes: 9, items: 3}} =
             ArtifactStore.append(store, items, item_bytes, item_ends: [3, 6, 9])

    assert {:ok, %{reference: item_ref}} = ArtifactStore.finish(store, items, :complete)
    {:ok, item_range} = Range.new(:page, :items, 1, 1, :unknown)

    assert {:ok,
            %{
              bytes: "β\n",
              selection: %{start: 1, count: 1, total: 3},
              reference: ^item_ref,
              capture: :complete
            }} = ArtifactStore.fetch(store, item_ref, item_range)
  end

  test "retains exact bytes through store and root quota restarts", %{tmp_dir: root} do
    quota_id = {:quota, make_ref()}
    store_id = {:store, make_ref()}
    quota = start_quota(root, quota_id)
    store = start_store(root, quota, "restart-session", store_id)
    captured = "before source mutation 💾\n"
    capture = begin_capture(store, "restart-call", :bytes, "text/plain")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, captured)
    assert {:ok, %{reference: reference}} = ArtifactStore.finish(store, capture, :complete)

    :ok = stop_supervised(store_id)
    :ok = stop_supervised(quota_id)

    restarted_quota = start_quota(root, quota_id)
    restarted_store = start_store(root, restarted_quota, "restart-session", store_id)
    {:ok, range} = Range.new(:full, :bytes, 0, byte_size(captured), byte_size(captured))

    assert {:ok, %{bytes: ^captured, reference: ^reference}} =
             ArtifactStore.fetch(restarted_store, reference, range)
  end

  test "delivery lookup distinguishes open captures and survives result-persistence delay and restart",
       %{
         tmp_dir: root
       } do
    quota = start_quota(root, {:quota, make_ref()})
    store_id = {:store, make_ref()}
    store = start_store(root, quota, "delivery-session", store_id)
    delivery_key = {:delivery, "checkpoint-1", "delivery-call"}
    capture = begin_capture(store, "delivery-call", :bytes, "text/plain")

    assert {:error, :delivery_in_progress} =
             ArtifactStore.lookup_delivery(store, delivery_key)

    assert {:ok, _progress} = ArtifactStore.append(store, capture, "durable before result")
    assert {:ok, stored} = ArtifactStore.finish(store, capture, :complete)
    assert {:ok, ^stored} = ArtifactStore.lookup_delivery(store, delivery_key)

    assert {:error, :unknown_delivery} =
             ArtifactStore.lookup_delivery(store, {:delivery, "checkpoint-1", "unknown-call"})

    :ok = stop_supervised(store_id)
    restarted = start_store(root, quota, "delivery-session", store_id)
    assert {:ok, ^stored} = ArtifactStore.lookup_delivery(restarted, delivery_key)
  end

  test "delivery lookup settles a dead capture owner as an interrupted durable prefix", %{
    tmp_dir: root
  } do
    {_quota, store} = start_pair(root, "owner-down-session")

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    owner_monitor = Process.monitor(owner)
    delivery_key = {:delivery, "checkpoint-1", "owner-down-call"}

    assert {:ok, spec} =
             CaptureSpec.new(
               media_type: "text/plain",
               mode: :bytes,
               owner_pid: owner,
               delivery_key: delivery_key
             )

    assert {:ok, capture} = ArtifactStore.begin(store, spec)
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "owned prefix")
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}

    assert {:ok, %{capture: {:incomplete, :interrupted}, reference: reference}} =
             ArtifactStore.lookup_delivery(store, delivery_key)

    {:ok, full} = Range.new(:full, :bytes, 0, 12, 12)
    assert {:ok, %{bytes: "owned prefix"}} = ArtifactStore.fetch(store, reference, full)
  end

  test "distinguishes foreign, unknown, and explicitly expired references", %{tmp_dir: root} do
    {quota, store} = start_pair(root, "authorized-session")
    foreign = start_store(root, quota, "foreign-session", {:foreign_store, make_ref()})
    capture = begin_capture(store, "authorization-call", :bytes, "text/plain")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "retained")
    assert {:ok, %{reference: reference}} = ArtifactStore.finish(store, capture, :complete)
    {:ok, full} = Range.new(:full, :bytes, 0, 8, 8)

    assert {:ok, ^reference} = ArtifactStore.reference(store, reference.token)
    assert {:error, :unauthorized} = ArtifactStore.reference(foreign, reference.token)
    assert {:error, :unauthorized} = ArtifactStore.fetch(foreign, reference, full)

    unknown = unknown_reference("authorized-session")
    assert {:error, :unknown_reference} = ArtifactStore.fetch(store, unknown, full)
    assert {:error, :unknown_reference} = ArtifactStore.reference(store, unknown.token)

    assert :ok =
             ArtifactStore.pin(store, {:snapshot, "generation-1"}, [reference],
               transfer_delivery: true
             )

    assert :ok = ArtifactStore.release(store, {:snapshot, "generation-1"})
    assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(store)
    assert {:error, :expired} = ArtifactStore.fetch(store, reference, full)
    assert {:error, :expired} = ArtifactStore.reference(store, reference.token)
  end

  test "pin replacement is atomic and cleanup never deletes referenced content", %{tmp_dir: root} do
    {_quota, store} = start_pair(root, "pin-session")
    capture = begin_capture(store, "pin-call", :bytes, "text/plain")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "pinned")
    assert {:ok, %{reference: reference}} = ArtifactStore.finish(store, capture, :complete)

    assert :ok =
             ArtifactStore.pin(store, {:task, "task-1", "generation-1"}, [reference],
               transfer_delivery: true
             )

    assert {:error, :unknown_reference} =
             ArtifactStore.pin(
               store,
               {:task, "task-1", "generation-1"},
               [unknown_reference("pin-session")]
             )

    assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)
    {:ok, full} = Range.new(:full, :bytes, 0, 6, 6)
    assert {:ok, %{bytes: "pinned"}} = ArtifactStore.fetch(store, reference, full)

    assert :ok = ArtifactStore.release(store, {:task, "task-1", "generation-1"})
    assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(store)
  end

  test "restart recovers an unfinished prefix as interrupted instead of expiring it", %{
    tmp_dir: root
  } do
    quota = start_quota(root, {:quota, make_ref()})
    store_id = {:store, make_ref()}
    store = start_store(root, quota, "interrupted-session", store_id)
    capture = begin_capture(store, "interrupted-call", :bytes, "text/plain")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "durable prefix")

    :ok = stop_supervised(store_id)
    restarted = start_store(root, quota, "interrupted-session", store_id)

    assert {:ok, ^capture} =
             ArtifactStore.begin(
               restarted,
               capture_spec("interrupted-call", :bytes, "text/plain")
             )

    assert {:ok, %{capture: {:incomplete, :interrupted}, reference: reference}} =
             ArtifactStore.finish(restarted, capture, {:incomplete, :interrupted})

    {:ok, full} = Range.new(:full, :bytes, 0, 14, 14)

    assert {:ok, %{bytes: "durable prefix", capture: {:incomplete, :interrupted}}} =
             ArtifactStore.fetch(restarted, reference, full)
  end

  test "injected disk full is visible and retains an honest incomplete empty prefix", %{
    tmp_dir: root
  } do
    quota = start_quota(root, {:quota, make_ref()})

    store =
      start_store(root, quota, "disk-full-session", {:store, make_ref()},
        fault_injector: %{before_blob_write: {:error, :enospc}}
      )

    capture = begin_capture(store, "disk-full-call", :bytes, "text/plain")
    assert {:error, :disk_full} = ArtifactStore.append(store, capture, "not admitted to disk")

    assert {:error, {:capture_incomplete, :disk_full}} =
             ArtifactStore.finish(store, capture, :complete)

    assert {:ok, %{capture: {:incomplete, :disk_full}, reference: reference}} =
             ArtifactStore.finish(store, capture, {:incomplete, :disk_full})

    {:ok, empty} = Range.new(:full, :bytes, 0, 0, 0)

    assert {:ok, %{bytes: <<>>, capture: {:incomplete, :disk_full}}} =
             ArtifactStore.fetch(store, reference, empty)
  end

  test "fault between blob and index writes truncates both files to the exact indexed prefix", %{
    tmp_dir: root
  } do
    quota = start_quota(root, {:quota, make_ref()})
    fault_key = {:partial_index_fault, make_ref()}

    injector = fn
      :before_index_write ->
        case Process.get(fault_key, 0) do
          0 ->
            Process.put(fault_key, 1)
            :ok

          _count ->
            {:error, :enospc}
        end

      _point ->
        :ok
    end

    store =
      start_store(root, quota, "partial-index-session", {:store, make_ref()},
        fault_injector: injector
      )

    capture = begin_capture(store, "partial-index-call", :items, "text/plain")

    assert {:ok, %{bytes: 6, items: 1}} =
             ArtifactStore.append(store, capture, "first\n", item_ends: [6])

    assert {:error, :disk_full} =
             ArtifactStore.append(store, capture, "second\n", item_ends: [7])

    assert {:error, {:capture_incomplete, :disk_full}} =
             ArtifactStore.finish(store, capture, :complete)

    assert {:ok, %{capture: {:incomplete, :disk_full}, reference: reference}} =
             ArtifactStore.finish(store, capture, {:incomplete, :disk_full})

    assert reference.bytes == 6
    assert reference.items == 1
    assert reference.sha256 == Reference.digest("first\n")
    {:ok, bytes} = Range.new(:full, :bytes, 0, 6, 6)
    assert {:ok, %{bytes: "first\n"}} = ArtifactStore.fetch(store, reference, bytes)
  end

  test "begin metadata failure compensates the reservation before any manifest exists", %{
    tmp_dir: root
  } do
    quota = start_quota(root, {:quota, make_ref()})

    store =
      start_store(root, quota, "metadata-compensation-session", {:store, make_ref()},
        fault_injector: %{before_capture_metadata: {:error, :enospc}}
      )

    before_usage = ArtifactQuota.usage(quota)

    assert {:error, :disk_full} =
             ArtifactStore.begin(
               store,
               capture_spec("metadata-compensation-call", :bytes, "text/plain")
             )

    assert ArtifactQuota.usage(quota) == before_usage

    assert {:error, :unknown_delivery} =
             ArtifactStore.lookup_delivery(
               store,
               {:delivery, "checkpoint-1", "metadata-compensation-call"}
             )
  end

  test "begin failures after quota admission remove the manifest row and restore quota", %{
    tmp_dir: root
  } do
    quota = start_quota(root, {:quota, make_ref()})

    store =
      start_store(root, quota, "begin-compensation-session", {:store, make_ref()},
        fault_injector: %{before_capture_files: {:error, :enospc}}
      )

    before_usage = ArtifactQuota.usage(quota)

    assert {:error, :disk_full} =
             ArtifactStore.begin(
               store,
               capture_spec("begin-compensation-call", :bytes, "text/plain")
             )

    assert ArtifactQuota.usage(quota) == before_usage

    assert {:error, :unknown_delivery} =
             ArtifactStore.lookup_delivery(
               store,
               {:delivery, "checkpoint-1", "begin-compensation-call"}
             )
  end

  test "cancel removes an open capture and all of its durable quota charge", %{tmp_dir: root} do
    {quota, store} = start_pair(root, "cancel-session")
    before_usage = ArtifactQuota.usage(quota)
    capture = begin_capture(store, "cancel-call", :items, "text/plain")

    assert {:ok, %{bytes: 5, items: 1}} =
             ArtifactStore.append(store, capture, "item\n", item_ends: [5])

    assert :ok = ArtifactStore.cancel(store, capture)
    assert ArtifactQuota.usage(quota) == before_usage

    assert {:error, :unknown_delivery} =
             ArtifactStore.lookup_delivery(store, {:delivery, "checkpoint-1", "cancel-call"})
  end

  test "restart removes a manifest capture killed before its files were created", %{tmp_dir: root} do
    quota = start_quota(root, {:quota, make_ref()})
    store_id = {:store, make_ref()}

    store =
      start_store(root, quota, "missing-open-files-session", store_id,
        fault_injector: fn
          :before_capture_files -> Process.exit(self(), :kill)
          _point -> :ok
        end
      )

    before_usage = ArtifactQuota.usage(quota)

    store_monitor = Process.monitor(store)

    assert catch_exit(
             ArtifactStore.begin(
               store,
               capture_spec("missing-open-files-call", :bytes, "text/plain")
             )
           )

    assert_receive {:DOWN, ^store_monitor, :process, ^store, :killed}

    restarted =
      start_store(root, quota, "missing-open-files-session", {:restarted_store, make_ref()})

    assert ArtifactQuota.usage(quota) == before_usage

    assert {:error, :unknown_delivery} =
             ArtifactStore.lookup_delivery(
               restarted,
               {:delivery, "checkpoint-1", "missing-open-files-call"}
             )
  end

  test "requested blob and item-index block corruption is rejected without changing file size", %{
    tmp_dir: root
  } do
    {_quota, store} = start_pair(root, "block-corruption-session")
    block_bytes = Limits.integrity_block_bytes()
    payload = :binary.copy(<<0x41>>, block_bytes) <> :binary.copy(<<0x42>>, block_bytes)
    bytes_capture = begin_capture(store, "corrupt-bytes", :bytes, "application/octet-stream")

    assert {:ok, _progress} =
             ArtifactStore.append(store, bytes_capture, binary_part(payload, 0, block_bytes))

    assert {:ok, _progress} =
             ArtifactStore.append(
               store,
               bytes_capture,
               binary_part(payload, block_bytes, block_bytes)
             )

    assert {:ok, %{reference: byte_ref}} =
             ArtifactStore.finish(store, bytes_capture, :complete)

    byte_paths = artifact_paths(root, "block-corruption-session", byte_ref)
    overwrite_byte(byte_paths.blob, Limits.blob_header_bytes() + block_bytes + 7, 0x43)
    {:ok, byte_page} = Range.new(:page, :bytes, block_bytes + 7, 1, :unknown)
    assert {:error, :artifact_corrupt} = ArtifactStore.fetch(store, byte_ref, byte_page)

    item_count = 9_000
    item_payload = :binary.copy("x", item_count)
    item_capture = begin_capture(store, "corrupt-index", :items, "text/plain")

    assert {:ok, _progress} =
             ArtifactStore.append(store, item_capture, item_payload,
               item_ends: Enum.to_list(1..item_count)
             )

    assert {:ok, %{reference: item_ref}} =
             ArtifactStore.finish(store, item_capture, :complete)

    {:ok, crossing_page} = Range.new(:page, :items, 8_000, 500, :unknown)

    assert {:ok, %{bytes: crossing_bytes, selection: %{start: 8_000, count: 500}}} =
             ArtifactStore.fetch(store, item_ref, crossing_page)

    assert crossing_bytes == :binary.copy("x", 500)

    item_paths = artifact_paths(root, "block-corruption-session", item_ref)
    overwrite_byte(item_paths.index, Limits.index_header_bytes() + block_bytes + 11, 0xFF)
    {:ok, item_page} = Range.new(:page, :items, 8_500, 1, :unknown)
    assert {:error, :artifact_corrupt} = ArtifactStore.fetch(store, item_ref, item_page)
  end

  test "terminal fetch rejects a missing proof instead of backfilling it", %{tmp_dir: root} do
    quota = start_quota(root, {:quota, make_ref()})
    store_id = {:store, make_ref()}
    session_id = "missing-proof-session"
    store = start_store(root, quota, session_id, store_id)
    capture = begin_capture(store, "missing-proof", :bytes, "text/plain")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "proof required")
    assert {:ok, %{reference: reference}} = ArtifactStore.finish(store, capture, :complete)
    :ok = stop_supervised(store_id)

    {:ok, _namespace, artifact_id} = Reference.parse(reference.token)
    db_path = namespace_db_path(root, session_id)
    {:ok, db} = SQLite.open(db_path, [])

    assert {:ok, :deleted} =
             SQLite.transaction(db, fn ->
               with :ok <-
                      SQLite.execute(
                        db,
                        "DELETE FROM artifact_blocks WHERE artifact_id = ?1 AND file_kind = 0",
                        [artifact_id]
                      ) do
                 {:ok, :deleted}
               end
             end)

    :ok = SQLite.close(db)
    restarted = start_store(root, quota, session_id, store_id)
    {:ok, full} = Range.new(:full, :bytes, 0, 14, 14)
    assert {:error, :artifact_corrupt} = ArtifactStore.fetch(restarted, reference, full)
  end

  test "restart trims an invalid item-offset suffix and retains the honest prefix", %{
    tmp_dir: root
  } do
    quota = start_quota(root, {:quota, make_ref()})
    store_id = {:store, make_ref()}
    session_id = "offset-recovery-session"
    store = start_store(root, quota, session_id, store_id)
    capture = begin_capture(store, "offset-recovery", :items, "text/plain")

    assert {:ok, %{bytes: 8, items: 2}} =
             ArtifactStore.append(store, capture, "one\ntwo\n", item_ends: [4, 8])

    :ok = stop_supervised(store_id)
    paths = capture_paths(root, session_id, capture.id)
    :ok = File.write(paths.index_partial, <<8::unsigned-big-64, 1, 2, 3>>, [:append])
    restarted = start_store(root, quota, session_id, store_id)

    assert {:ok, ^capture} =
             ArtifactStore.begin(
               restarted,
               capture_spec("offset-recovery", :items, "text/plain")
             )

    assert {:ok, %{capture: {:incomplete, :interrupted}, reference: reference}} =
             ArtifactStore.finish(restarted, capture, {:incomplete, :interrupted})

    assert reference.bytes == 8
    assert reference.items == 2
    {:ok, second} = Range.new(:page, :items, 1, 1, :unknown)
    assert {:ok, %{bytes: "two\n"}} = ArtifactStore.fetch(restarted, reference, second)
  end

  test "delivery lookup finalizes a dormant durable prefix after finish loses its active handle",
       %{
         tmp_dir: root
       } do
    faults = :atomics.new(1, [])

    injector = fn
      :before_blob_rename ->
        if :atomics.get(faults, 1) == 1, do: {:error, :rename_failed}, else: :ok

      _point ->
        :ok
    end

    {_quota, store} =
      start_pair_with_store_opts(root, "dormant-lookup-session", fault_injector: injector)

    delivery_key = {:delivery, "checkpoint-1", "dormant-lookup"}
    capture = begin_capture(store, "dormant-lookup", :bytes, "text/plain")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "durable prefix")
    :ok = :atomics.put(faults, 1, 1)
    assert {:error, :rename_failed} = ArtifactStore.finish(store, capture, :complete)

    :ok = :atomics.put(faults, 1, 0)

    assert {:ok, %{capture: {:incomplete, :interrupted}, reference: reference}} =
             ArtifactStore.lookup_delivery(store, delivery_key)

    {:ok, full} = Range.new(:full, :bytes, 0, 14, 14)
    assert {:ok, %{bytes: "durable prefix"}} = ArtifactStore.fetch(store, reference, full)
  end

  test "failed owner-down finalization blocks mutation until reopen recovers the prefix", %{
    tmp_dir: root
  } do
    faults = :atomics.new(1, [])

    injector = fn
      :before_blob_rename ->
        if :atomics.get(faults, 1) == 1, do: {:error, :owner_down_rename_failed}, else: :ok

      _point ->
        :ok
    end

    quota = start_quota(root, {:quota, make_ref()})
    store_id = {:store, make_ref()}
    session_id = "owner-down-failure-session"
    store = start_store(root, quota, session_id, store_id, fault_injector: injector)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, spec} =
             CaptureSpec.new(
               media_type: "text/plain",
               mode: :bytes,
               owner_pid: owner,
               delivery_key: {:delivery, "checkpoint-1", "owner-down-failure"}
             )

    assert {:ok, capture} = ArtifactStore.begin(store, spec)
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "owner prefix")
    :ok = :atomics.put(faults, 1, 1)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}

    assert {:error, _finalization_failure} =
             ArtifactStore.lookup_delivery(
               store,
               {:delivery, "checkpoint-1", "owner-down-failure"}
             )

    assert %{blocked: true} = :sys.get_state(store)

    assert {:error, :storage_unavailable} =
             ArtifactStore.begin(
               store,
               capture_spec("blocked-after-owner-down", :bytes, "text/plain")
             )

    :ok = :atomics.put(faults, 1, 0)
    :ok = stop_supervised(store_id)
    reopened = start_store(root, quota, session_id, store_id, fault_injector: injector)

    assert {:ok, %{capture: {:incomplete, :interrupted}, reference: reference}} =
             ArtifactStore.lookup_delivery(
               reopened,
               {:delivery, "checkpoint-1", "owner-down-failure"}
             )

    {:ok, full} = Range.new(:full, :bytes, 0, 12, 12)
    assert {:ok, %{bytes: "owner prefix"}} = ArtifactStore.fetch(reopened, reference, full)
  end

  test "terminal finish stays readable and blocks mutation when quota reconciliation degrades", %{
    tmp_dir: root
  } do
    faults = :atomics.new(1, [])

    quota_injector = fn
      :before_quota_checkpoint ->
        if :atomics.get(faults, 1) == 1, do: {:error, :checkpoint_busy}, else: :ok

      _point ->
        :ok
    end

    quota =
      start_quota(root, {:quota, make_ref()}, fault_injector: quota_injector)

    store = start_store(root, quota, "finish-accounting-session", {:store, make_ref()})
    capture = begin_capture(store, "finish-accounting", :bytes, "text/plain")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "committed bytes")
    :ok = :atomics.put(faults, 1, 1)

    assert {:ok, %{reference: reference}} = ArtifactStore.finish(store, capture, :complete)
    {:ok, full} = Range.new(:full, :bytes, 0, 15, 15)
    assert {:ok, %{bytes: "committed bytes"}} = ArtifactStore.fetch(store, reference, full)

    assert {:error, :storage_unavailable} =
             ArtifactStore.begin(store, capture_spec("blocked-growth", :bytes, "text/plain"))
  end

  test "cleanup sync failure neither expires nor decharges deleted content", %{tmp_dir: root} do
    faults = :atomics.new(1, [])

    injector = fn
      :before_blob_delete_sync ->
        if :atomics.get(faults, 1) == 1, do: {:error, :sync_failed}, else: :ok

      _point ->
        :ok
    end

    quota = start_quota(root, {:quota, make_ref()})
    store_id = {:store, make_ref()}
    session_id = "cleanup-sync-session"
    store = start_store(root, quota, session_id, store_id, fault_injector: injector)
    capture = begin_capture(store, "cleanup-sync", :bytes, "text/plain")
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "delete me")
    assert {:ok, %{reference: reference}} = ArtifactStore.finish(store, capture, :complete)
    assert :ok = ArtifactStore.release(store, {:delivery, "checkpoint-1", "cleanup-sync"})
    charged = ArtifactQuota.usage(quota)

    :ok = :atomics.put(faults, 1, 1)
    assert {:error, :sync_failed} = ArtifactStore.cleanup_unreferenced(store)
    assert ArtifactQuota.usage(quota) == charged
    assert {:error, :storage_unavailable} = ArtifactStore.cleanup_unreferenced(store)

    :ok = :atomics.put(faults, 1, 0)
    :ok = stop_supervised(store_id)
    reopened = start_store(root, quota, session_id, store_id, fault_injector: injector)
    assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(reopened)
    assert {:error, :expired} = ArtifactStore.fetch(reopened, reference, byte_range(9))
    assert ArtifactQuota.usage(quota).artifacts == 0
  end

  defp start_pair_with_store_opts(root, session_id, opts) do
    quota = start_quota(root, {:quota, make_ref()})
    store = start_store(root, quota, session_id, {:store, make_ref()}, opts)
    {quota, store}
  end

  defp byte_range(bytes) do
    assert {:ok, range} = Range.new(:full, :bytes, 0, bytes, bytes)
    range
  end

  defp start_pair(root, session_id) do
    quota = start_quota(root, {:quota, make_ref()})
    store = start_store(root, quota, session_id, {:store, make_ref()})
    {quota, store}
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
        {ArtifactStore, Keyword.merge([root: root, quota: quota, session_id: session_id], opts)},
        id: id,
        restart: :temporary
      )

    start_supervised!(child)
  end

  defp begin_capture(store, call_id, mode, media_type) do
    assert {:ok, capture} = ArtifactStore.begin(store, capture_spec(call_id, mode, media_type))
    capture
  end

  defp capture_spec(call_id, mode, media_type) do
    assert {:ok, spec} =
             CaptureSpec.new(
               media_type: media_type,
               mode: mode,
               owner_pid: self(),
               delivery_key: {:delivery, "checkpoint-1", call_id}
             )

    spec
  end

  defp artifact_paths(root, session_id, reference) do
    {:ok, _namespace, artifact_id} = Reference.parse(reference.token)
    capture_paths(root, session_id, artifact_id)
  end

  defp capture_paths(root, session_id, artifact_id) do
    directory = Path.join([root, "namespaces", Reference.namespace(session_id)])
    {:ok, paths} = Paths.new(directory, artifact_id)
    paths
  end

  defp namespace_db_path(root, session_id) do
    Path.join([root, "namespaces", Reference.namespace(session_id), "artifacts.sqlite3"])
  end

  defp overwrite_byte(path, offset, byte) do
    {:ok, io} = :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])
    :ok = :file.pwrite(io, offset, <<byte>>)
    :ok = :file.close(io)
  end

  defp unknown_reference(session_id) do
    token = "artifact:1:#{Reference.namespace(session_id)}:#{String.duplicate("A", 32)}"

    assert {:ok, reference} =
             Reference.new(
               token: token,
               media_type: "text/plain",
               bytes: 8,
               sha256: String.duplicate("0", 64)
             )

    reference
  end
end

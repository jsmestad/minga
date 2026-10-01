defmodule MingaAgent.ArtifactStoresTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.ArtifactStore.Limits
  alias MingaAgent.ArtifactStores
  alias MingaAgent.ArtifactSupervisor
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tool.Output.Range

  @moduletag :tmp_dir

  test "record actors are lazy and concurrent admission returns one namespace writer", %{
    tmp_dir: root
  } do
    {_supervisor, runtime} = start_runtime(root)
    assert Registry.lookup(runtime.registry, "shared-record") == []

    stores =
      1..16
      |> Task.async_stream(
        fn _index -> ArtifactStores.ensure_record("shared-record", runtime) end,
        ordered: false,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, {:ok, store}} -> store end)

    assert [_store] = Enum.uniq(stores)
    assert [_entry] = Registry.lookup(runtime.registry, "shared-record")
    assert %{namespaces: 1} = ArtifactQuota.usage(runtime.quota)
  end

  test "one record open failure does not crash the runtime or block another record", %{
    tmp_dir: root
  } do
    {_supervisor, runtime} = start_runtime(root)
    namespace = MingaAgent.Tool.Output.Reference.namespace("unsafe-record")
    assert {:ok, _limits} = ArtifactQuota.register_namespace(runtime.quota, root, namespace)

    directory = Path.join([root, "namespaces", namespace])
    :ok = File.mkdir_p(Path.join(directory, "artifacts.sqlite3"))

    assert {:error, _reason} = ArtifactStores.ensure_record("unsafe-record", runtime)
    assert {:ok, _store} = ArtifactStores.ensure_record("healthy-record", runtime)
  end

  test "quota restart replaces registry and every record actor without restarting callers", %{
    tmp_dir: root
  } do
    {supervisor, runtime} = start_runtime(root)
    {:ok, old_store} = ArtifactStores.ensure_record("restart-record", runtime)
    old_store_monitor = Process.monitor(old_store)
    old_quota = Process.whereis(runtime.quota)

    Process.exit(old_quota, :kill)
    assert_receive {:DOWN, ^old_store_monitor, :process, ^old_store, _reason}
    :sys.get_state(supervisor)

    new_quota = Process.whereis(runtime.quota)
    refute new_quota == old_quota
    assert Registry.lookup(runtime.registry, "restart-record") == []
    assert {:ok, new_store} = ArtifactStores.ensure_record("restart-record", runtime)
    refute new_store == old_store
  end

  test "explicit record deletion reclaims namespace bytes, counts, and slot", %{tmp_dir: root} do
    envelope = Limits.sqlite_envelope_bytes()

    {_supervisor, runtime} =
      start_runtime(root,
        limits: [
          root_bytes: envelope * 3,
          session_bytes: envelope + 1024,
          capture_bytes: 1024,
          image_bytes: 1024,
          append_bytes: 1024,
          root_namespaces: 1
        ]
      )

    {:ok, store} = ArtifactStores.ensure_record("deleted-record", runtime)
    capture = begin_capture(store, "delete-call")
    assert {:ok, _stored} = ArtifactStore.finish(store, capture, :complete)
    assert %{namespaces: 1, artifacts: 1} = ArtifactQuota.usage(runtime.quota)

    assert :ok = ArtifactStores.delete_record("deleted-record", runtime)

    assert %{bytes: ^envelope, namespaces: 0, artifacts: 0, open_captures: 0} =
             ArtifactQuota.usage(runtime.quota)

    assert :ok = ArtifactStores.delete_record("deleted-record", runtime)

    assert {:ok, _replacement} = ArtifactStores.ensure_record("replacement-record", runtime)
  end

  test "ordinary store termination retains the record and its delivery", %{tmp_dir: root} do
    {_supervisor, runtime} = start_runtime(root)
    {:ok, store} = ArtifactStores.ensure_record("retained-record", runtime)
    capture = begin_capture(store, "retained-call")
    assert {:ok, stored} = ArtifactStore.finish(store, capture, :complete)

    assert :ok = DynamicSupervisor.terminate_child(runtime.store_supervisor, store)
    assert %{namespaces: 1, artifacts: 1} = ArtifactQuota.usage(runtime.quota)

    assert {:ok, reopened} = ArtifactStores.ensure_record("retained-record", runtime)

    assert {:ok, ^stored} =
             ArtifactStore.lookup_delivery(
               reopened,
               {:delivery, "checkpoint-1", "retained-call"}
             )
  end

  test "record deletion rejects an active capture", %{tmp_dir: root} do
    {_supervisor, runtime} = start_runtime(root)
    {:ok, store} = ArtifactStores.ensure_record("active-record", runtime)
    capture = begin_capture(store, "active-call")

    assert {:error, :record_in_use} = ArtifactStores.delete_record("active-record", runtime)
    assert {:ok, _stored} = ArtifactStore.finish(store, capture, :complete)
    assert :ok = ArtifactStores.delete_record("active-record", runtime)
  end

  test "a failure after durable unlink keeps conservative quota until explicit retry", %{
    tmp_dir: root
  } do
    quota = start_quota(root, {:quota, make_ref()})

    store =
      start_store(root, quota, "partial-delete-record", {:faulted_store, make_ref()},
        fault_injector: %{after_namespace_delete: {:error, :injected_delete_failure}}
      )

    capture = begin_capture(store, "partial-delete-call")
    assert {:ok, _stored} = ArtifactStore.finish(store, capture, :complete)
    usage_before = ArtifactQuota.usage(quota)
    store_monitor = Process.monitor(store)
    assert {:error, :injected_delete_failure} = ArtifactStore.delete_record(store)
    assert_receive {:DOWN, ^store_monitor, :process, ^store, _reason}

    assert ArtifactQuota.usage(quota) == usage_before

    retry_store =
      start_store(root, quota, "partial-delete-record", {:retry_store, make_ref()})

    assert :ok = ArtifactStore.delete_record(retry_store)
    assert %{namespaces: 0, artifacts: 0} = ArtifactQuota.usage(quota)
  end

  test "cross-record copy rewrites foreign tokens and preserves exact bounded bytes", %{
    tmp_dir: root
  } do
    {_supervisor, runtime} = start_runtime(root)
    {:ok, source} = ArtifactStores.ensure_record("copy-source", runtime)
    capture = begin_capture(source, "copy-call")
    bytes = String.duplicate("copy-safe-å", 8_000)

    for chunk <- Enum.chunk_every(:binary.bin_to_list(bytes), 65_536) do
      assert {:ok, _progress} =
               ArtifactStore.append(source, capture, :binary.list_to_bin(chunk), item_ends: [])
    end

    assert {:ok, stored} = ArtifactStore.finish(source, capture, :complete)
    assert {:ok, selection} = Range.new(:full, :bytes, 0, byte_size(bytes), byte_size(bytes))

    assert {:ok, output} =
             Output.new("copy-safe", :complete, selection, reference: stored.reference)

    assert {:ok, copied} =
             ArtifactStores.copy_output(
               "copy-source",
               "copy-target",
               output,
               "fork-operation-1",
               runtime
             )

    refute copied.reference.token == stored.reference.token
    assert copied.reference.sha256 == stored.reference.sha256
    {:ok, target} = ArtifactStores.ensure_record("copy-target", runtime)
    assert {:ok, fetched} = ArtifactStore.fetch(target, copied.reference, selection)
    assert fetched.bytes == bytes
    assert {:error, :unauthorized} = ArtifactStore.fetch(target, stored.reference, selection)
  end

  test "failed multi-reference copy releases prior deliveries and cancels the active capture", %{
    tmp_dir: root
  } do
    {_supervisor, runtime} = start_runtime(root)
    {:ok, source} = ArtifactStores.ensure_record("copy-failure-source", runtime)
    primary = store_reference(source, "copy-primary", "primary bytes", "text/plain")
    image = store_reference(source, "copy-image", <<137, 80, 78, 71>>, "image/png")
    {:ok, attachment} = Attachment.image(image, "copied.png")
    {:ok, selection} = Range.new(:full, :bytes, 0, primary.bytes, primary.bytes)

    assert {:ok, output} =
             Output.new("copy failure", :complete, selection,
               reference: primary,
               attachments: [attachment]
             )

    fault_counter = :atomics.new(1, signed: false)

    target =
      start_runtime_store(runtime, "copy-failure-target", fn
        :before_capture_files ->
          case :atomics.add_get(fault_counter, 1, 1) do
            2 -> {:error, :enospc}
            _first_capture -> :ok
          end

        _point ->
          :ok
      end)

    usage_before = ArtifactQuota.usage(runtime.quota)
    copy_id = "copy-failure-operation"

    assert {:error, {:artifact_copy_failed, :disk_full}} =
             ArtifactStores.copy_output(
               "copy-failure-source",
               "copy-failure-target",
               output,
               copy_id,
               runtime
             )

    assert ArtifactQuota.usage(runtime.quota) == usage_before
    operation = MingaAgent.Tool.Output.Reference.digest(copy_id)

    for reference <- [primary, image] do
      delivery =
        {:delivery, operation, MingaAgent.Tool.Output.Reference.digest(reference.token)}

      assert {:error, :unknown_delivery} = ArtifactStore.lookup_delivery(target, delivery)
    end

    assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(target)
  end

  defp start_runtime(root, opts \\ []) do
    suffix = System.unique_integer([:positive])

    runtime_opts =
      Keyword.merge(
        [
          name: Module.concat(__MODULE__, "Supervisor#{suffix}"),
          root: root,
          quota: Module.concat(__MODULE__, "Quota#{suffix}"),
          registry: Module.concat(__MODULE__, "Registry#{suffix}"),
          store_supervisor: Module.concat(__MODULE__, "Stores#{suffix}")
        ],
        opts
      )

    child =
      Supervisor.child_spec({ArtifactSupervisor, runtime_opts},
        id: {:artifact_runtime, suffix},
        restart: :temporary
      )

    supervisor = start_supervised!(child)
    {:ok, runtime} = ArtifactSupervisor.runtime(runtime_opts)
    {supervisor, runtime}
  end

  defp start_quota(root, id) do
    child =
      Supervisor.child_spec({ArtifactQuota, root: root}, id: id, restart: :temporary)

    start_supervised!(child)
  end

  defp start_store(root, quota, record_id, id, opts \\ []) do
    child =
      Supervisor.child_spec(
        {ArtifactStore, Keyword.merge([root: root, quota: quota, session_id: record_id], opts)},
        id: id,
        restart: :temporary
      )

    start_supervised!(child)
  end

  defp start_runtime_store(runtime, session_id, fault_injector) do
    name = {:via, Registry, {runtime.registry, session_id}}

    child =
      Supervisor.child_spec(
        {ArtifactStore,
         root: runtime.root,
         quota: runtime.quota,
         session_id: session_id,
         limits: runtime.limits,
         name: name,
         fault_injector: fault_injector},
        restart: :transient
      )

    {:ok, store} = DynamicSupervisor.start_child(runtime.store_supervisor, child)
    store
  end

  defp begin_capture(store, call_id) do
    {:ok, spec} =
      CaptureSpec.new(
        media_type: "text/plain",
        mode: :bytes,
        owner_pid: self(),
        delivery_key: {:delivery, "checkpoint-1", call_id}
      )

    {:ok, capture} = ArtifactStore.begin(store, spec)
    capture
  end

  defp store_reference(store, call_id, bytes, media_type) do
    {:ok, spec} =
      CaptureSpec.new(
        media_type: media_type,
        mode: :bytes,
        owner_pid: self(),
        delivery_key: {:delivery, "checkpoint-1", call_id}
      )

    {:ok, capture} = ArtifactStore.begin(store, spec)
    assert {:ok, _progress} = ArtifactStore.append(store, capture, bytes)
    assert {:ok, stored} = ArtifactStore.finish(store, capture, :complete)
    stored.reference
  end
end

defmodule MingaAgent.Tools.RetainedShellStreamTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tools.OutputCapture

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    quota =
      start_supervised!(
        Supervisor.child_spec({ArtifactQuota, root: root},
          id: {:quota, make_ref()},
          restart: :temporary
        )
      )

    %{root: root, quota: quota}
  end

  test "stream splits finite appends and preserves Unicode beyond the preview boundary",
       context do
    {_id, store} = start_store(context)
    bytes = String.duplicate("x", 51_199) <> "€\t \n" <> String.duplicate("λ", 50_000)
    key = {:delivery, "checkpoint", "unicode"}
    assert {:ok, capture} = OutputCapture.begin_stream(store, key)
    assert :ok = OutputCapture.append_stream(store, capture, bytes)

    assert {:ok, output} =
             OutputCapture.finish_stream(
               store,
               capture,
               binary_part(bytes, 0, 51_200),
               :complete,
               ""
             )

    assert output.view == String.duplicate("x", 51_199)
    assert output.presentation == {:truncated, byte_size(bytes) - 51_199}
    assert output.capture == :complete
    assert output.reference.bytes == byte_size(bytes)
    assert fetch_bytes(store, output.reference) == bytes
  end

  test "binary preview is bounded while every binary byte remains recoverable", context do
    {_id, store} = start_store(context)
    bytes = :binary.copy(<<255, 0, 254, 128>>, 40_000)
    assert {:ok, capture} = OutputCapture.begin_stream(store, {:delivery, "checkpoint", "binary"})
    assert :ok = OutputCapture.append_stream(store, capture, bytes)

    assert {:ok, output} =
             OutputCapture.finish_stream(
               store,
               capture,
               binary_part(bytes, 0, 51_200),
               :complete,
               ""
             )

    assert String.valid?(output.view)
    assert byte_size(output.view) <= 51_200
    assert "[base64 shell output]\n" <> base64 = output.view
    preview_bytes = Base.decode64!(base64)
    assert preview_bytes == binary_part(bytes, 0, byte_size(preview_bytes))
    assert output.presentation == {:truncated, byte_size(bytes) - byte_size(preview_bytes)}
    assert fetch_bytes(store, output.reference) == bytes
  end

  test "owner interruption retains more than the UI cap and settles through delivery lookup",
       context do
    {_id, store} = start_store(context)
    parent = self()
    bytes = String.duplicate("retained λ \t\n", 6_000)
    key = {:delivery, "checkpoint", "interrupted"}

    owner =
      spawn(fn ->
        {:ok, capture} = OutputCapture.begin_stream(store, key)
        :ok = OutputCapture.append_stream(store, capture, bytes)
        send(parent, :prefix_stored)

        receive do
          :finish -> :ok
        end
      end)

    monitor = Process.monitor(owner)
    assert_receive :prefix_stored
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert {:ok, %{reference: reference, capture: {:incomplete, :interrupted}}} =
             ArtifactStore.lookup_delivery(store, key)

    assert reference.bytes == byte_size(bytes)
    assert reference.bytes > 51_200
    assert fetch_bytes(store, reference) == bytes
  end

  test "disk-full after an accepted append preserves only that exact prefix", context do
    injector = fn
      :before_blob_write ->
        case Process.get(:write_count, 0) do
          0 ->
            Process.put(:write_count, 1)
            :ok

          _ ->
            {:error, :enospc}
        end

      _ ->
        :ok
    end

    {_id, store} = start_store(context, fault_injector: injector)
    assert {:ok, capture} = OutputCapture.begin_stream(store, {:delivery, "checkpoint", "disk"})
    prefix = "durable λ \t\n"
    assert :ok = OutputCapture.append_stream(store, capture, prefix)
    assert {:error, :disk_full} = OutputCapture.append_stream(store, capture, "not durable")

    assert {:error, output} =
             OutputCapture.finish_stream(
               store,
               capture,
               prefix <> "not durable",
               {:incomplete, :disk_full},
               "\n[capture incomplete: :disk_full]"
             )

    assert output.capture == {:incomplete, :disk_full}
    assert output.reference.bytes == byte_size(prefix)
    assert output.view == prefix <> "\n[capture incomplete: :disk_full]"
    assert fetch_bytes(store, output.reference) == prefix
  end

  test "store exit during capture cannot fabricate a successful reference", context do
    {id, store} = start_store(context)

    assert {:ok, capture} =
             OutputCapture.begin_stream(store, {:delivery, "checkpoint", "store-down"})

    assert :ok = OutputCapture.append_stream(store, capture, "prefix")
    assert :ok = stop_supervised(id)
    assert {:error, :storage_unavailable} = OutputCapture.append_stream(store, capture, "later")

    assert {:error, :storage_unavailable} =
             OutputCapture.finish_stream(store, capture, "prefix", :complete, "")
  end

  test "terminal storage failure is returned instead of a complete output", context do
    {_id, store} = start_store(context, fault_injector: %{before_blob_rename: {:error, :eio}})

    assert {:ok, capture} =
             OutputCapture.begin_stream(store, {:delivery, "checkpoint", "finish-failure"})

    assert :ok = OutputCapture.append_stream(store, capture, "prefix")
    assert {:error, :eio} = OutputCapture.finish_stream(store, capture, "prefix", :complete, "")
  end

  defp start_store(%{root: root, quota: quota}, opts \\ []) do
    id = {:store, make_ref()}

    store =
      start_supervised!(
        Supervisor.child_spec(
          {ArtifactStore, [root: root, quota: quota, session_id: "stream-owner"] ++ opts},
          id: id,
          restart: :temporary
        )
      )

    {id, store}
  end

  defp fetch_bytes(store, reference) do
    starts =
      if reference.bytes == 0, do: [0], else: Enum.to_list(0..(reference.bytes - 1)//51_200)

    Enum.map_join(starts, fn start ->
      count = min(51_200, reference.bytes - start)
      assert {:ok, range} = Range.new(:page, :bytes, start, count, reference.bytes)
      assert {:ok, fetched} = ArtifactStore.fetch(store, reference, range)
      fetched.bytes
    end)
  end
end

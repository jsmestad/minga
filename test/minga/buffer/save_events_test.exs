defmodule Minga.Buffer.SaveEventsTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events

  setup do
    suffix = System.unique_integer([:positive])
    registry = Module.concat(__MODULE__, "Events#{suffix}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    :ok = Events.subscribe(:buffer_saved, registry)
    %{registry: registry, suffix: suffix}
  end

  @tag :tmp_dir
  test "normal and forced saves publish authoritative source-owned events", ctx do
    path = Path.join(ctx.tmp_dir, "saved.txt")
    File.write!(path, "original")
    buffer = start_buffer(path, ctx)

    assert :ok = BufferProcess.insert_text(buffer, "normal ")
    assert :ok = BufferProcess.save(buffer)
    assert_saved(buffer, path)

    assert :ok = BufferProcess.insert_text(buffer, "forced ")
    assert :ok = BufferProcess.force_save(buffer)
    assert_saved(buffer, path)
  end

  @tag :tmp_dir
  test "save_if_version saves and broadcasts when the version matches", ctx do
    path = Path.join(ctx.tmp_dir, "save-if-version.txt")
    File.write!(path, "original")
    buffer = start_buffer(path, ctx)

    assert :ok = BufferProcess.insert_text(buffer, "new ")
    version = BufferProcess.version(buffer)

    assert :ok = BufferProcess.save_if_version(buffer, version)
    assert File.read!(path) == "new original"
    refute BufferProcess.dirty?(buffer)
    assert_saved(buffer, path)
  end

  @tag :tmp_dir
  test "save_if_version rejects read-only save transforms without mutation", ctx do
    path = Path.join(ctx.tmp_dir, "save-if-version-read-only.txt")
    File.write!(path, "line  \n")

    buffer =
      start_supervised!(
        {BufferProcess,
         file_path: path, content: "line  \n", read_only: true, events_registry: ctx.registry},
        id: {BufferProcess, ctx.suffix}
      )

    version = BufferProcess.version(buffer)

    assert {:error, :read_only} =
             BufferProcess.save_if_version(buffer, version, trim_trailing_whitespace: true)

    assert BufferProcess.content(buffer) == "line  \n"
    assert File.read!(path) == "line  \n"
    refute_receive {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: ^buffer}}
  end

  @tag :tmp_dir
  test "save_if_version rejects stale content", ctx do
    path = Path.join(ctx.tmp_dir, "save-if-version-stale.txt")
    File.write!(path, "original")
    buffer = start_buffer(path, ctx)

    version = BufferProcess.version(buffer)
    assert :ok = BufferProcess.insert_text(buffer, "new ")

    assert {:error, :stale} = BufferProcess.save_if_version(buffer, version)
    assert File.read!(path) == "original"
    assert BufferProcess.dirty?(buffer)
    refute_receive {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: ^buffer}}
  end

  @tag :tmp_dir
  test "save_as_if_version rejects stale content and publishes no saved event", ctx do
    target = Path.join(ctx.tmp_dir, "save-as-if-version-stale.txt")
    buffer = start_scratch(ctx)
    version = BufferProcess.version(buffer)

    assert :ok = BufferProcess.insert_text(buffer, "new ")
    assert {:error, :stale} = BufferProcess.save_as_if_version(buffer, version, target, [])

    refute File.exists?(target)
    assert BufferProcess.dirty?(buffer)
    refute_receive {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: ^buffer}}
  end

  @tag :tmp_dir
  test "save-as publishes the adopted target and failed saves publish nothing", ctx do
    target = Path.join(ctx.tmp_dir, "adopted.txt")
    buffer = start_scratch(ctx)

    assert :ok = BufferProcess.insert_text(buffer, "content")
    assert :ok = BufferProcess.save_as(buffer, target)
    assert_saved(buffer, target)

    failed = start_scratch(%{ctx | suffix: ctx.suffix + 1})
    assert {:error, :no_file_path} = BufferProcess.save(failed)
    refute_receive {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: ^failed}}
  end

  defp start_buffer(path, ctx) do
    start_supervised!(
      {BufferProcess, file_path: path, events_registry: ctx.registry},
      id: {BufferProcess, ctx.suffix}
    )
  end

  defp start_scratch(ctx) do
    start_supervised!(
      {BufferProcess, content: "", events_registry: ctx.registry},
      id: {BufferProcess, ctx.suffix}
    )
  end

  defp assert_saved(buffer, path) do
    assert_receive {:minga_event, :buffer_saved,
                    %Events.BufferEvent{buffer: ^buffer, path: ^path}}
  end
end

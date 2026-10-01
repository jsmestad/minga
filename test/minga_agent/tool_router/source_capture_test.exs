defmodule MingaAgent.ToolRouter.SourceCaptureTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Fork
  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.Tool.Limitation
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.ToolRouter.Context
  alias MingaAgent.ToolRouter.SourceCapture

  @moduletag :tmp_dir
  @moduletag :heavy
  @capture_bytes 16 * 1_024 * 1_024

  test "capture limit retains only complete UTF-8 code points", %{tmp_dir: root} do
    path = Path.join(root, "boundary.txt")
    bytes = :binary.copy("a", @capture_bytes - 1) <> "€after-limit"
    File.write!(path, bytes)
    store = start_store(Path.join(root, "artifacts"))

    assert {:error, output} =
             SourceCapture.capture(
               %Context{},
               path,
               store,
               {:delivery, "utf8-boundary", "read"},
               []
             )

    assert output.capture == {:incomplete, :capture_byte_limit}
    assert output.reference.bytes == @capture_bytes - 1
    assert {:ok, fetched} = ArtifactStore.fetch(store, output.reference, output.selection)
    assert String.valid?(fetched.bytes)
    assert fetched.bytes == :binary.copy("a", @capture_bytes - 1)
  end

  test "a completed disk line request stops before EOF and reports an unknown total", %{
    tmp_dir: root
  } do
    path = Path.join(root, "requested.txt")
    File.write!(path, "first\n" <> :binary.copy("later line\n", 20_000))
    store = start_store(Path.join(root, "artifacts"))

    assert {:ok, output} =
             SourceCapture.capture(
               %Context{},
               path,
               store,
               {:delivery, "requested-prefix", "read"},
               offset: 1,
               limit: 1
             )

    assert output.capture == :complete
    assert output.selection.start == 0
    assert output.selection.count == 1
    assert output.selection.total == :unknown
    assert output.view == "first"
  end

  test "buffer and fork owners return bounded prefixes without copying full unsaved content", %{
    tmp_dir: root
  } do
    path = Path.join(root, "unsaved.txt")
    oversized = :binary.copy("u", @capture_bytes + 1)
    {:ok, buffer} = start_supervised({Minga.Buffer.Process, content: oversized, file_path: path})
    assert :ok = Buffer.replace_content(buffer, oversized)

    assert {prefix, _version, false} = Buffer.content_prefix_with_version(buffer, 1_024)
    assert prefix == :binary.copy("u", 1_024)

    {:ok, fork_store} = start_supervised(BufferForkStore)
    {:ok, fork} = BufferForkStore.get_or_create(fork_store, path, buffer)
    Fork.replace_content(fork, :binary.copy("f", @capture_bytes + 1))

    assert {fork_prefix, _fork_version, false} = Fork.content_prefix_with_version(fork, 1_024)
    assert fork_prefix == :binary.copy("f", 1_024)
  end

  test "line capture bytes match across routed owners without changing full-file bytes", %{
    tmp_dir: root
  } do
    bytes = :binary.copy("skipped\n", 20_000) <> "å\n尾\nkept trailing\n"
    selected = "å\n尾"
    store = start_store(Path.join(root, "parity-artifacts"))
    disk_path = Path.join(root, "disk-lines.txt")
    buffer_path = Path.join(root, "buffer-lines.txt")
    fork_path = Path.join(root, "fork-lines.txt")
    changeset_path = Path.join(root, "changeset-lines.txt")
    direct_path = Path.join(root, "direct-lines.txt")
    overlay_path = Path.join(root, "overlay-lines.txt")

    for path <- [disk_path, direct_path], do: File.write!(path, bytes)

    {:ok, buffer} =
      start_supervised(
        Supervisor.child_spec(
          {Minga.Buffer.Process, content: bytes, file_path: buffer_path},
          id: {:line_parity_buffer, make_ref()}
        )
      )

    assert :ok = Buffer.replace_content(buffer, bytes)

    {:ok, fork_source} =
      start_supervised(
        Supervisor.child_spec(
          {Minga.Buffer.Process, content: "ancestor", file_path: fork_path},
          id: {:line_parity_fork_source, make_ref()}
        )
      )

    {:ok, fork_store} = start_supervised(BufferForkStore)
    {:ok, fork} = BufferForkStore.get_or_create(fork_store, fork_path, fork_source)
    assert :ok = Fork.replace_content(fork, bytes)

    changeset = start_supervised!({MingaAgent.Changeset.Server, project_root: root})
    assert :ok = Changeset.write_file(changeset, "changeset-lines.txt", bytes)
    {:ok, direct_view} = ProjectView.direct(root)
    {:ok, overlay_view} = ProjectView.overlay(root)
    assert :ok = ProjectView.write_file(overlay_view, "overlay-lines.txt", bytes)

    on_exit(fn ->
      ProjectView.close(direct_view)
      ProjectView.close(overlay_view)
    end)

    sources = [
      {%Context{}, disk_path},
      {%Context{}, buffer_path},
      {%Context{fork_store: fork_store}, fork_path},
      {%Context{changeset: changeset}, changeset_path},
      {%Context{project_view: direct_view}, direct_path},
      {%Context{project_view: overlay_view}, overlay_path}
    ]

    {:ok, selected_range} =
      Range.new(:full, :bytes, 0, byte_size(selected), byte_size(selected))

    for {{context, path}, index} <- Enum.with_index(sources) do
      assert {:ok, output} =
               SourceCapture.capture(
                 context,
                 path,
                 store,
                 {:delivery, "line-parity-#{index}", "read"},
                 offset: 20_001,
                 limit: 2
               )

      assert output.capture == :complete
      assert output.selection.start == 20_000
      assert output.selection.count == 2
      assert output.view == selected
      assert output.reference.bytes == byte_size(selected)

      assert {:ok, %{bytes: ^selected}} =
               ArtifactStore.fetch(store, output.reference, selected_range)
    end

    assert {:ok, full_output} =
             SourceCapture.capture(
               %Context{},
               disk_path,
               store,
               {:delivery, "full-file-parity", "read"},
               []
             )

    assert {:ok, %{bytes: ^bytes}} =
             ArtifactStore.fetch(store, full_output.reference, full_output.selection)
  end

  test "unsupported image delivery is refused before size validation or artifact capture", %{
    tmp_dir: root
  } do
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :binary.copy(<<0>>, 6 * 1_024 * 1_024)
    store = start_store(Path.join(root, "unsupported-artifacts"))
    disk_path = Path.join(root, "disk.png")
    buffer_path = Path.join(root, "buffer.png")
    fork_path = Path.join(root, "fork.png")
    File.write!(disk_path, bytes)

    {:ok, buffer} =
      start_supervised(
        Supervisor.child_spec(
          {Minga.Buffer.Process, content: bytes, file_path: buffer_path},
          id: {:unsupported_buffer, make_ref()}
        )
      )

    assert :ok = Buffer.replace_content(buffer, bytes)

    {:ok, fork_source} =
      start_supervised(
        Supervisor.child_spec(
          {Minga.Buffer.Process, content: "source", file_path: fork_path},
          id: {:unsupported_fork_source, make_ref()}
        )
      )

    {:ok, fork_store} = start_supervised(BufferForkStore)
    {:ok, fork} = BufferForkStore.get_or_create(fork_store, fork_path, fork_source)
    Fork.replace_content(fork, bytes)

    changeset = start_supervised!({MingaAgent.Changeset.Server, project_root: root})
    changeset_path = Path.join(root, "changeset.png")
    assert :ok = Changeset.write_file(changeset, "changeset.png", bytes)
    {:ok, direct_view} = ProjectView.direct(root)
    {:ok, overlay_view} = ProjectView.overlay(root, fork_store: fork_store)
    assert :ok = ProjectView.write_file(overlay_view, "overlay.png", bytes)

    on_exit(fn ->
      ProjectView.close(direct_view)
      ProjectView.close(overlay_view)
    end)

    sources = [
      {%Context{}, disk_path, {:delivery, "unsupported-disk", "read"}},
      {%Context{}, buffer_path, {:delivery, "unsupported-buffer", "read"}},
      {%Context{fork_store: fork_store}, fork_path, {:delivery, "unsupported-fork", "read"}},
      {%Context{changeset: changeset}, changeset_path,
       {:delivery, "unsupported-changeset", "read"}},
      {%Context{project_view: direct_view}, disk_path,
       {:delivery, "unsupported-direct-view", "read"}},
      {%Context{project_view: overlay_view}, buffer_path,
       {:delivery, "unsupported-overlay-buffer", "read"}},
      {%Context{project_view: overlay_view}, fork_path,
       {:delivery, "unsupported-overlay-fork", "read"}},
      {%Context{project_view: overlay_view}, Path.join(root, "overlay.png"),
       {:delivery, "unsupported-overlay-edit", "read"}}
    ]

    for {context, path, delivery_key} <- sources do
      assert {:error,
              %Limitation{
                reason: :tool_result_transport,
                filename: filename,
                media_type: "image/png"
              }} =
               SourceCapture.capture(context, path, store, delivery_key,
                 image_tool_result_delivery: {:unsupported, :tool_result_transport}
               )

      assert filename == Path.basename(path)
      assert {:error, :unknown_delivery} = ArtifactStore.lookup_delivery(store, delivery_key)
    end
  end

  test "late changeset line capture retains exact selected bytes and source identity", %{
    tmp_dir: root
  } do
    changeset = start_supervised!({MingaAgent.Changeset.Server, project_root: root})
    path = Path.join(root, "late.txt")
    bytes = :binary.copy("skipped\n", 20_000) <> "å\n尾\n" <> :binary.copy("unused\n", 20_000)
    assert :ok = Changeset.write_file(changeset, "late.txt", bytes)
    store = start_store(Path.join(root, "late-artifacts"))

    assert {:ok, output} =
             SourceCapture.capture(
               %Context{changeset: changeset},
               path,
               store,
               {:delivery, "late", "read"},
               offset: 20_001,
               limit: 2
             )

    assert output.capture == :complete
    assert output.revision.source_id == path
    assert output.revision.source_kind == :changeset

    {:ok, range} = Range.new(:full, :bytes, 0, 6, 6)
    assert {:ok, %{bytes: "å\n尾"}} = ArtifactStore.fetch(store, output.reference, range)
  end

  defp start_store(root) do
    quota =
      start_supervised!(
        Supervisor.child_spec(
          {ArtifactQuota, root: root},
          id: {:source_capture_quota, make_ref()},
          restart: :temporary
        )
      )

    start_supervised!(
      Supervisor.child_spec(
        {ArtifactStore, root: root, quota: quota, session_id: "source-capture-session"},
        id: {:source_capture_store, make_ref()},
        restart: :temporary
      )
    )
  end
end

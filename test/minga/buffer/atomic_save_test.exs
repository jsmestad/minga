defmodule Minga.Buffer.AtomicSaveTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]
  import ExUnit.CaptureLog

  alias Minga.Buffer.ControllableFileSystem
  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :tmp_dir
  @acknowledgement_timeout 2_000
  @original <<0, 1, 2, "previous bytes">>

  for stage <- [:open, :write, :flush, :metadata, :rename] do
    @stage stage

    test "#{stage} failure preserves the target and dirty buffer and removes temporary files",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "#{@stage}.txt")
      File.write!(path, @original)

      buffer =
        start_buffer(
          file_path: path,
          persistence_file_system: ControllableFileSystem,
          persistence_file_system_options: [fail_at: @stage]
        )

      assert :ok = BufferProcess.replace_content(buffer, "new content", :user)
      assert BufferProcess.dirty?(buffer)

      assert {:error, {:injected, @stage}} = BufferProcess.save(buffer)
      assert File.read!(path) == @original
      assert BufferProcess.content(buffer) == "new content"
      assert BufferProcess.dirty?(buffer)
      assert directory_entries(tmp_dir) == [Path.basename(path)]
    end
  end

  test "new temporary file is mode 0600 before content writing begins", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "restricted-open.txt")
    File.write!(path, "original")
    parent = self()

    buffer =
      start_buffer(
        file_path: path,
        persistence_file_system: ControllableFileSystem,
        persistence_file_system_options: [open_controller: parent]
      )

    assert :ok = BufferProcess.replace_content(buffer, "private replacement", :user)
    save = Task.async(fn -> BufferProcess.save(buffer) end)

    assert_receive {:local_save_temp_opened, ^buffer, temporary}, @acknowledgement_timeout
    assert band(File.stat!(temporary).mode, 0o7777) == 0o600
    assert File.read!(temporary) == ""

    send(buffer, :continue_local_save_write)
    assert Task.await(save) == :ok
    assert File.read!(path) == "private replacement"
    refute File.exists?(temporary)
  end

  test "restrictive temporary chmod failure preserves the target and dirty buffer", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "open-permissions.txt")
    File.write!(path, @original)

    buffer =
      start_buffer(
        file_path: path,
        persistence_file_system: ControllableFileSystem,
        persistence_file_system_options: [fail_at: :open_permissions]
      )

    assert :ok = BufferProcess.replace_content(buffer, "private replacement", :user)
    assert BufferProcess.save(buffer) == {:error, {:injected, :open_permissions}}
    assert File.read!(path) == @original
    assert BufferProcess.dirty?(buffer)
    assert directory_entries(tmp_dir) == [Path.basename(path)]
  end

  test "successful replacement preserves mode and ownership and removes its temporary file", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "preserve.txt")
    File.write!(path, @original)
    File.chmod!(path, 0o640)
    original_stat = File.stat!(path)
    buffer = start_buffer(file_path: path)

    assert :ok = BufferProcess.replace_content(buffer, "committed content", :user)
    assert :ok = BufferProcess.force_save(buffer)

    replacement_stat = File.stat!(path)
    assert File.read!(path) == "committed content"
    assert band(replacement_stat.mode, 0o7777) == band(original_stat.mode, 0o7777)
    assert replacement_stat.uid == original_stat.uid
    assert replacement_stat.gid == original_stat.gid
    refute BufferProcess.dirty?(buffer)
    assert directory_entries(tmp_dir) == [Path.basename(path)]
  end

  test "concurrent exclusive saves use unique siblings and only one commits", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "unique.txt")
    parent = self()

    first =
      Task.async(fn ->
        Minga.Buffer.Persistence.LocalWriter.write(
          path,
          "first",
          :exclusive_create,
          ControllableFileSystem,
          controller: parent
        )
      end)

    second =
      Task.async(fn ->
        Minga.Buffer.Persistence.LocalWriter.write(
          path,
          "second",
          :exclusive_create,
          ControllableFileSystem,
          controller: parent
        )
      end)

    assert_receive {:local_save_before_commit, first_writer, first_temp, ^path},
                   @acknowledgement_timeout

    assert_receive {:local_save_before_commit, second_writer, second_temp, ^path},
                   @acknowledgement_timeout

    assert first_writer != second_writer
    assert first_temp != second_temp
    assert Path.dirname(first_temp) == Path.dirname(path)
    assert Path.dirname(second_temp) == Path.dirname(path)

    send(first_writer, :continue_local_save_commit)
    send(second_writer, :continue_local_save_commit)

    assert [first_result, second_result] = Enum.sort([Task.await(first), Task.await(second)])
    assert first_result == :ok
    assert second_result == {:error, :eexist}
    assert File.read!(path) in ["first", "second"]
    assert directory_entries(tmp_dir) == [Path.basename(path)]
  end

  test "exclusive save does not replace a target that appears at the commit boundary", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "appeared.txt")

    buffer =
      start_buffer(
        content: "local",
        persistence_file_system: ControllableFileSystem,
        persistence_file_system_options: [controller: self()]
      )

    assert :ok = BufferProcess.insert_text(buffer, "edited ")
    version = BufferProcess.version(buffer)
    assert {:ok, intent} = BufferProcess.prepare_save_as(buffer, path, false)

    save =
      Task.async(fn ->
        BufferProcess.save_as_if_version(buffer, version, intent, [])
      end)

    assert_receive {:local_save_before_commit, ^buffer, temporary, ^path},
                   @acknowledgement_timeout

    File.write!(path, "external")
    send(buffer, :continue_local_save_commit)

    assert Task.await(save) == {:error, :file_exists}
    assert File.read!(path) == "external"
    assert BufferProcess.file_path(buffer) == nil
    assert BufferProcess.dirty?(buffer)
    refute File.exists?(temporary)
    assert directory_entries(tmp_dir) == [Path.basename(path)]
  end

  test "post-link cleanup failure reports the exclusive save as committed", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "committed.txt")

    buffer =
      start_buffer(
        content: "committed content",
        persistence_file_system: ControllableFileSystem,
        persistence_file_system_options: [fail_at: :cleanup]
      )

    version = BufferProcess.version(buffer)
    assert {:ok, intent} = BufferProcess.prepare_save_as(buffer, path, false)

    log =
      capture_log(fn ->
        assert :ok = BufferProcess.save_as_if_version(buffer, version, intent, [])
      end)

    assert File.read!(path) == "committed content"
    assert BufferProcess.file_path(buffer) == path
    refute BufferProcess.dirty?(buffer)
    assert log =~ "Local save committed but could not remove temporary file"

    [temporary] =
      tmp_dir
      |> directory_entries()
      |> Enum.reject(&(&1 == Path.basename(path)))

    File.rm!(Path.join(tmp_dir, temporary))
  end

  defp start_buffer(opts) do
    start_supervised!({BufferProcess, opts}, id: {:buffer, make_ref()})
  end

  defp directory_entries(directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
  end
end

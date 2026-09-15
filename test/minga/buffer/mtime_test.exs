defmodule Minga.Buffer.MtimeTest do
  @moduledoc """
  Save-conflict behavior for file-backed buffers.

  These tests avoid asserting on stored mtime fields directly. The contract is whether saves, force-saves, reloads, and dirty state behave correctly when the file changes on disk.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Buffer.SaveIntent

  @tag :tmp_dir
  test ":w returns :file_changed when file size differs on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "conflict.txt")
    File.write!(path, "original")
    buf = start_buffer(file_path: path)

    File.write!(path, "externally modified with longer content")
    BufferProcess.insert_char(buf, "x")

    assert BufferProcess.save(buf) == {:error, :file_changed}
    assert BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test ":w ignores metadata-only changes when file content still matches", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "touched.txt")
    File.write!(path, "original")
    %{mtime: original_mtime} = File.stat!(path, time: :posix)
    buf = start_buffer(file_path: path)
    File.touch!(path, original_mtime + 10)

    BufferProcess.insert_char(buf, "x")

    assert BufferProcess.save(buf) == :ok
    assert File.read!(path) == "xoriginal"
    refute BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test ":w! force-saves despite file change on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "force.txt")
    File.write!(path, "original")
    buf = start_buffer(file_path: path)

    File.write!(path, "externally modified with longer content")
    BufferProcess.insert_char(buf, "forced")

    assert BufferProcess.force_save(buf) == :ok
    assert File.read!(path) == "forcedoriginal"
    refute BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test ":e! reloads buffer from disk and clears dirty state", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "reload.txt")
    File.write!(path, "line1\nline2\nline3")
    buf = start_buffer(file_path: path)
    BufferProcess.insert_char(buf, "x")
    assert BufferProcess.dirty?(buf)

    File.write!(path, "reloaded content")

    assert :ok = BufferProcess.reload(buf)
    assert BufferProcess.content(buf) == "reloaded content"
    refute BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test ":e! clears undo and redo history", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "undo.txt")
    File.write!(path, "original")
    buf = start_buffer(file_path: path)
    BufferProcess.insert_char(buf, "change1")
    BufferProcess.insert_char(buf, "change2")
    assert BufferProcess.last_undo_source(buf) != nil

    assert :ok = BufferProcess.reload(buf)

    assert BufferProcess.last_undo_source(buf) == nil
    assert BufferProcess.last_redo_source(buf) == nil
  end

  @tag :tmp_dir
  test ":e! preserves cursor position clamped to new content", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "clamp.txt")
    File.write!(path, "line1\nline2\nline3\nline4\nline5")
    buf = start_buffer(file_path: path)
    BufferProcess.move_to(buf, {4, 3})

    File.write!(path, "short\nfile")

    assert :ok = BufferProcess.reload(buf)
    {line, col} = BufferProcess.cursor(buf)
    assert line <= 1
    assert col <= 3
  end

  @tag :tmp_dir
  test "reloads allocate unique revisions across undo and redo branches", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "revisions.txt")
    File.write!(path, "first")
    buf = start_buffer(file_path: path)
    initial_version = BufferProcess.version(buf)

    File.write!(path, "second")
    assert :ok = BufferProcess.reload(buf)
    first_reload_version = BufferProcess.version(buf)
    assert first_reload_version > initial_version
    refute BufferProcess.dirty?(buf)

    assert :ok = BufferProcess.insert_text(buf, "edited ")
    edit_version = BufferProcess.version(buf)
    assert edit_version > first_reload_version

    assert :ok = BufferProcess.undo(buf)
    assert BufferProcess.version(buf) == first_reload_version
    assert BufferProcess.content(buf) == "second"
    refute BufferProcess.dirty?(buf)

    assert :ok = BufferProcess.redo(buf)
    assert BufferProcess.version(buf) == edit_version
    assert BufferProcess.content(buf) == "edited second"
    assert BufferProcess.dirty?(buf)

    assert :ok = BufferProcess.undo(buf)
    assert :ok = BufferProcess.insert_text(buf, "branched ")
    branch_version = BufferProcess.version(buf)
    assert branch_version > edit_version

    File.write!(path, "third")
    assert :ok = BufferProcess.reload(buf)
    second_reload_version = BufferProcess.version(buf)
    assert second_reload_version > branch_version
    assert BufferProcess.content(buf) == "third"
    refute BufferProcess.dirty?(buf)
    assert BufferProcess.last_undo_source(buf) == nil
    assert BufferProcess.last_redo_source(buf) == nil

    assert {:error, :stale} =
             BufferProcess.replace_content_if_version(buf, initial_version, "obsolete", :lsp)

    assert BufferProcess.content(buf) == "third"
    assert BufferProcess.version(buf) == second_reload_version

    assert {:ok, formatted_version} =
             BufferProcess.replace_content_if_version(
               buf,
               second_reload_version,
               "formatted third",
               :lsp
             )

    assert formatted_version > second_reload_version
    assert BufferProcess.content(buf) == "formatted third"
    assert BufferProcess.dirty?(buf)
    assert :ok = BufferProcess.undo(buf)
    assert BufferProcess.content(buf) == "third"
    refute BufferProcess.dirty?(buf)
    assert :ok = BufferProcess.redo(buf)
    assert BufferProcess.content(buf) == "formatted third"
    assert BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test "open preserves revision allocation and failed open or reload leaves state unchanged", %{
    tmp_dir: tmp_dir
  } do
    first_path = Path.join(tmp_dir, "first.txt")
    second_path = Path.join(tmp_dir, "second.txt")
    missing_path = Path.join(tmp_dir, "missing.txt")
    File.write!(first_path, "first")
    File.write!(second_path, "second")
    buf = start_buffer(file_path: first_path)

    assert :ok = BufferProcess.insert_text(buf, "edited ")
    edit_version = BufferProcess.version(buf)
    assert :ok = BufferProcess.undo(buf)
    assert BufferProcess.version(buf) == 0

    assert :ok = BufferProcess.open(buf, second_path)
    opened_version = BufferProcess.version(buf)
    assert opened_version > edit_version
    assert BufferProcess.file_path(buf) == second_path
    assert BufferProcess.content(buf) == "second"
    refute BufferProcess.dirty?(buf)
    assert BufferProcess.last_undo_source(buf) == nil

    assert :ok = BufferProcess.move_to(buf, {0, 3})
    assert :ok = BufferProcess.insert_text(buf, " local")
    before_failed_open = buffer_snapshot(buf)

    assert {:error, :enoent} = BufferProcess.open(buf, missing_path)
    assert buffer_snapshot(buf) == before_failed_open

    File.rm!(second_path)
    assert {:error, :enoent} = BufferProcess.reload(buf)
    assert buffer_snapshot(buf) == before_failed_open
  end

  @tag :tmp_dir
  test ":w works when file was deleted on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "deleted.txt")
    File.write!(path, "exists")
    buf = start_buffer(file_path: path)
    File.rm!(path)

    BufferProcess.insert_char(buf, "new content")

    assert BufferProcess.save(buf) == :ok
    assert File.read!(path) == "new contentexists"
  end

  test "reload and force_save on scratch buffers return errors" do
    buf = start_buffer(content: "scratch")

    assert BufferProcess.reload(buf) == {:error, :no_file_path}
    assert BufferProcess.force_save(buf) == {:error, :no_file_path}
  end

  @tag :tmp_dir
  test "save_as writes scratch content to a file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "saveas.txt")
    buf = start_buffer(content: "new file")

    assert :ok = BufferProcess.save_as(buf, path)
    assert File.read!(path) == "new file"
    assert BufferProcess.file_path(buf) == path
    refute BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test "save_as adopts the path as the buffer's identity", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "parser.ex")
    buf = start_buffer(content: "defmodule Parser do\nend\n", buffer_name: "Untitled-1")

    assert :ok = BufferProcess.save_as(buf, path)

    assert BufferProcess.buffer_name(buf) == nil
    assert BufferProcess.display_name(buf) == "parser.ex"
    assert BufferProcess.filetype(buf) == :elixir
  end

  @tag :tmp_dir
  test "non-forced save intent for the current path preserves external changes", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "same-path.txt")
    File.write!(path, "original")
    buf = start_buffer(file_path: path)
    BufferProcess.insert_text(buf, "local ")
    version = BufferProcess.version(buf)

    assert {:ok, intent} =
             BufferProcess.prepare_save_as(buf, Path.join(tmp_dir, "./same-path.txt"), false)

    File.write!(path, <<0, 1, 2, 255>>)

    assert {:error, :file_changed} =
             BufferProcess.save_as_if_version(buf, version, intent, [])

    assert File.read!(path) == <<0, 1, 2, 255>>
    assert BufferProcess.content(buf) == "local original"
    assert BufferProcess.file_path(buf) == path
    assert BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test "non-forced absent-target intent cannot overwrite a file created before commit", %{
    tmp_dir: tmp_dir
  } do
    target = Path.join(tmp_dir, "appeared.txt")
    buf = start_buffer(content: "local")
    BufferProcess.insert_text(buf, " edit")
    version = BufferProcess.version(buf)
    assert {:ok, intent} = BufferProcess.prepare_save_as(buf, target, false)

    File.write!(target, <<0, 1, 2, 255>>)

    assert {:error, :file_exists} =
             BufferProcess.save_as_if_version(buf, version, intent, [])

    assert File.read!(target) == <<0, 1, 2, 255>>
    assert BufferProcess.file_path(buf) == nil
    assert BufferProcess.content(buf) == " editlocal"
    assert BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test "forced save intent does not grant overwrite consent to a later save", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, "forced-target.txt")
    File.write!(target, "first external")
    buf = start_buffer(content: "local")
    BufferProcess.insert_text(buf, "forced ")
    version = BufferProcess.version(buf)
    assert {:ok, intent} = BufferProcess.prepare_save_as(buf, target, true)

    assert :ok = BufferProcess.save_as_if_version(buf, version, intent, [])
    assert File.read!(target) == "forced local"

    File.write!(target, "second external")
    BufferProcess.insert_text(buf, "later ")

    assert {:error, :file_changed} = BufferProcess.save(buf)
    assert File.read!(target) == "second external"
    assert BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test "retargeting a buffer invalidates a captured current-file intent", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.txt")
    redirected = Path.join(tmp_dir, "redirected.txt")
    File.write!(source, "source")
    buf = start_buffer(file_path: source)
    BufferProcess.insert_text(buf, "local ")
    version = BufferProcess.version(buf)
    assert {:ok, intent} = BufferProcess.prepare_save_as(buf, source, true)
    assert :ok = BufferProcess.retarget_path(buf, redirected)

    assert {:error, :stale} = BufferProcess.save_as_if_version(buf, version, intent, [])
    assert File.read!(source) == "source"
    refute File.exists?(redirected)
    assert BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test "reloading a buffer invalidates a captured save intent even when the old version was clean",
       %{
         tmp_dir: tmp_dir
       } do
    path = Path.join(tmp_dir, "reload-intent.txt")
    File.write!(path, "original")
    buf = start_buffer(file_path: path)
    version = BufferProcess.version(buf)
    assert {:ok, intent} = BufferProcess.prepare_save_as(buf, path, true)

    File.write!(path, "reloaded")
    assert :ok = BufferProcess.reload(buf)

    assert {:error, :stale} = BufferProcess.save_as_if_version(buf, version, intent, [])
    assert File.read!(path) == "reloaded"
    assert BufferProcess.content(buf) == "reloaded"
    refute BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test "save intent cannot be committed by another scratch buffer", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, "scratch-origin.txt")
    origin = start_buffer(content: "origin")
    other = start_buffer(content: "other  ")
    assert {:ok, intent} = BufferProcess.prepare_save_as(origin, target, false)

    assert {:error, :invalid_save_intent} =
             BufferProcess.save_as_if_version(other, BufferProcess.version(other), intent,
               trim_trailing_whitespace: true
             )

    refute File.exists?(target)
    assert BufferProcess.content(other) == "other  "
    assert BufferProcess.file_path(other) == nil
  end

  @tag :tmp_dir
  test "save intent cannot be committed by another buffer sharing the same file path", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "shared-origin.txt")
    File.write!(path, "disk")
    origin = start_buffer(file_path: path)
    other = start_buffer(file_path: path)
    BufferProcess.insert_text(other, "other ")
    assert {:ok, intent} = BufferProcess.prepare_save_as(origin, path, true)

    assert {:error, :invalid_save_intent} =
             BufferProcess.save_as_if_version(other, BufferProcess.version(other), intent, [])

    assert File.read!(path) == "disk"
    assert BufferProcess.content(other) == "other disk"
    assert BufferProcess.dirty?(other)
  end

  @tag :tmp_dir
  test "inconsistent forged save intent policies are rejected before transforms or writes", %{
    tmp_dir: tmp_dir
  } do
    buffer = start_buffer(content: "local  ")

    forged_policies = [
      {false, :any},
      {true, :absent}
    ]

    Enum.each(forged_policies, fn {overwrite, expectation} ->
      target = Path.join(tmp_dir, "forged-#{overwrite}-#{expectation}.txt")
      File.write!(target, <<0, 1, 2, 255>>)

      intent = %SaveIntent{
        target: target,
        overwrite: overwrite,
        expectation: expectation,
        origin_buffer: buffer,
        origin_path: nil
      }

      assert {:error, :invalid_save_intent} =
               BufferProcess.save_as_if_version(buffer, BufferProcess.version(buffer), intent,
                 trim_trailing_whitespace: true
               )

      assert File.read!(target) == <<0, 1, 2, 255>>
      assert BufferProcess.content(buffer) == "local  "
      assert BufferProcess.file_path(buffer) == nil
    end)
  end

  @tag :tmp_dir
  test "non-forced save through a symlink alias uses current-file conflict policy", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "canonical.txt")
    alias_path = Path.join(tmp_dir, "alias.txt")
    File.write!(path, "original")
    File.ln_s!(path, alias_path)
    buffer = start_buffer(file_path: path)
    BufferProcess.insert_text(buffer, "local ")
    version = BufferProcess.version(buffer)

    assert {:ok, %SaveIntent{expectation: :current_file} = intent} =
             BufferProcess.prepare_save_as(buffer, alias_path, false)

    assert :ok = BufferProcess.save_as_if_version(buffer, version, intent, [])
    assert File.read!(path) == "local original"
    assert File.read!(alias_path) == "local original"
    assert BufferProcess.file_path(buffer) == path
    refute BufferProcess.dirty?(buffer)
  end

  @tag :tmp_dir
  test "non-forced save through a symlink alias preserves externally changed current file", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "canonical-conflict.txt")
    alias_path = Path.join(tmp_dir, "alias-conflict.txt")
    File.write!(path, "original")
    File.ln_s!(path, alias_path)
    buffer = start_buffer(file_path: path)
    BufferProcess.insert_text(buffer, "local ")
    version = BufferProcess.version(buffer)
    assert {:ok, intent} = BufferProcess.prepare_save_as(buffer, alias_path, false)
    File.write!(path, <<0, 1, 2, 255>>)

    assert {:error, :file_changed} =
             BufferProcess.save_as_if_version(buffer, version, intent, [])

    assert File.read!(path) == <<0, 1, 2, 255>>
    assert File.read!(alias_path) == <<0, 1, 2, 255>>
    assert BufferProcess.content(buffer) == "local original"
    assert BufferProcess.file_path(buffer) == path
    assert BufferProcess.dirty?(buffer)
  end

  defp start_buffer(opts) do
    buffer = start_supervised!({BufferProcess, opts}, id: {:buffer, make_ref()})
    assert {:ok, 0} = BufferProcess.set_option(buffer, :auto_save_delay_ms, 0)
    buffer
  end

  defp buffer_snapshot(buf) do
    %{
      content: BufferProcess.content(buf),
      cursor: BufferProcess.cursor(buf),
      version: BufferProcess.version(buf),
      dirty?: BufferProcess.dirty?(buf),
      undo_source: BufferProcess.last_undo_source(buf),
      redo_source: BufferProcess.last_redo_source(buf),
      file_path: BufferProcess.file_path(buf)
    }
  end
end

defmodule MingaEditor.Commands.BufferManagementSaveAsTest do
  @moduledoc false

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Config.Options

  @moduletag :tmp_dir

  setup do
    options_server = start_supervised!({Options, name: nil})
    assert {:ok, 0} = Options.set(options_server, :auto_save_delay_ms, 0)
    %{options_server: options_server}
  end

  test ":w with the current filename preserves external changes", %{
    tmp_dir: root,
    options_server: options_server
  } do
    path = Path.join(root, "current-write.txt")
    File.write!(path, "original")
    ctx = start_editor("original", file_path: path, options_server: options_server)
    assert :ok = Buffer.insert_text(ctx.buffer, "local ")
    File.write!(path, <<0, 1, 2, 255>>)

    send_ex_sync(ctx, "w #{path}")

    assert File.read!(path) == <<0, 1, 2, 255>>
    assert Buffer.content(ctx.buffer) == "local original"
    assert Buffer.file_path(ctx.buffer) == path
    assert Buffer.dirty?(ctx.buffer)
    assert notice_message(ctx) == "WARNING: File changed on disk. Use :w! to force save."
  end

  test ":saveas with the current filename preserves external changes", %{
    tmp_dir: root,
    options_server: options_server
  } do
    path = Path.join(root, "current-saveas.txt")
    File.write!(path, "original")
    ctx = start_editor("original", file_path: path, options_server: options_server)
    assert :ok = Buffer.insert_text(ctx.buffer, "local ")
    File.write!(path, "external newer\n")

    send_ex_sync(ctx, "saveas #{path}")

    assert File.read!(path) == "external newer\n"
    assert Buffer.content(ctx.buffer) == "local original"
    assert Buffer.file_path(ctx.buffer) == path
    assert Buffer.dirty?(ctx.buffer)
    assert notice_message(ctx) == "WARNING: File changed on disk. Use :w! to force save."
  end

  test "non-forced explicit write rejects another existing file without adopting it", %{
    tmp_dir: root,
    options_server: options_server
  } do
    source = Path.join(root, "source.txt")
    target = Path.join(root, "existing.txt")
    File.write!(source, "source")
    File.write!(target, <<0, 1, 2, 255>>)
    ctx = start_editor("source", file_path: source, options_server: options_server)
    assert :ok = Buffer.insert_text(ctx.buffer, "local ")

    send_ex_sync(ctx, "w #{target}")

    assert File.read!(target) == <<0, 1, 2, 255>>
    assert Buffer.file_path(ctx.buffer) == source
    assert Buffer.dirty?(ctx.buffer)
    assert notice_message(ctx) == "File exists: existing.txt (use :w! to override)"
  end

  test "forced explicit write adopts only its captured target and later plain save checks conflicts",
       %{
         tmp_dir: root,
         options_server: options_server
       } do
    target = Path.join(root, "force.txt")
    File.write!(target, "first external")
    ctx = start_editor("local", options_server: options_server)
    assert :ok = Buffer.insert_text(ctx.buffer, "forced ")

    send_ex_sync(ctx, "w! #{target}")

    assert File.read!(target) == "forced local"
    assert Buffer.file_path(ctx.buffer) == target
    refute Buffer.dirty?(ctx.buffer)

    File.write!(target, "second external")
    assert :ok = Buffer.insert_text(ctx.buffer, "later ")
    send_ex_sync(ctx, "w")

    assert File.read!(target) == "second external"
    assert Buffer.dirty?(ctx.buffer)
    assert notice_message(ctx) == "WARNING: File changed on disk. Use :w! to force save."
  end

  test "successful non-forced explicit write retains save-as identity behavior", %{
    tmp_dir: root,
    options_server: options_server
  } do
    target = Path.join(root, "named.ex")
    ctx = start_editor("defmodule Named, do: nil\n", options_server: options_server)
    assert :ok = Buffer.insert_text(ctx.buffer, "# saved\n")

    send_ex_sync(ctx, "saveas #{target}")

    assert File.read!(target) == "# saved\ndefmodule Named, do: nil\n"
    assert Buffer.file_path(ctx.buffer) == target
    assert Buffer.display_name(ctx.buffer) == "named.ex"
    assert Buffer.filetype(ctx.buffer) == :elixir
    refute Buffer.dirty?(ctx.buffer)
    assert {:ok, buffer} = Buffer.pid_for_path(target)
    assert buffer == ctx.buffer
    assert notice_message(ctx) == "Wrote named.ex"
  end
end

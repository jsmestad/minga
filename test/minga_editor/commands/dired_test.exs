defmodule MingaEditor.Commands.DiredTest do
  @moduledoc """
  Thin EditorCase smoke coverage for Dired input and navigation wiring.

  Listing behavior, keymap scope, and filesystem mutations are covered at
  cheaper direct boundaries.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :tmp_dir

  test "opens a listing, opens the selected file, and navigates to the parent", %{tmp_dir: dir} do
    file_path = Path.join(dir, "hello.txt")
    File.write!(file_path, "hello")

    ctx = start_editor("")
    send_ex_sync(ctx, "dired #{dir}")

    assert active_content(ctx) =~ "hello.txt"

    send_keys_sync(ctx, "<CR>")
    assert active_content(ctx) == "hello"
    assert BufferProcess.file_path(active_buffer(ctx)) == file_path

    subdir = Path.join(dir, "sub")
    File.mkdir_p!(subdir)
    File.write!(Path.join(subdir, "inner.txt"), "")
    send_ex_sync(ctx, "dired #{subdir}")

    send_keys_sync(ctx, "-")
    assert active_content(ctx) =~ "hello.txt"
    refute active_content(ctx) =~ "inner.txt"
  end
end

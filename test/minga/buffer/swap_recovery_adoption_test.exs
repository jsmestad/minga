defmodule Minga.Buffer.SwapRecoveryAdoptionTest do
  @moduledoc """
  A buffer that takes recovered text becomes the owner of that text on disk, and a buffer that releases its swap leaves nothing to recover.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery

  @moduletag :tmp_dir
  @moduletag capture_log: true

  # A swap that an editor with OS pid 4242 left behind.
  @dead_editor 4242

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "notes.txt")
    File.write!(path, "saved text")
    swap_dir = Path.join(tmp_dir, "swap")

    %{
      path: path,
      swap_dir: swap_dir,
      next_start: [swap_dir: swap_dir, pid_alive?: &(&1 != @dead_editor)]
    }
  end

  describe "adopt_recovered_text/3" do
    test "writes this buffer's own swap before it removes the one the text came from", ctx do
      old_swap = leftover_swap(ctx, "unsaved text")
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)
      own_swap = Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)

      assert :ok = adopt(buffer, old_swap, "unsaved text")

      # No debounce has run: a crash right now still finds the text on disk.
      assert Buffer.content(buffer) == "unsaved text"
      assert Buffer.dirty?(buffer)
      assert {:ok, %{path: path}, "unsaved text"} = Swap.read(own_swap)
      assert path == ctx.path
      refute File.exists?(old_swap)
    end

    test "saving the buffer afterwards leaves no swap to recover", ctx do
      old_swap = leftover_swap(ctx, "unsaved text")
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)

      :ok = adopt(buffer, old_swap, "unsaved text")
      :ok = Buffer.save(buffer)

      assert File.read!(ctx.path) == "unsaved text"
      assert File.ls!(ctx.swap_dir) == []
    end

    test "recovered text is not auto-saved until the user edits", ctx do
      registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      :ok = Minga.Events.subscribe(:buffer_saved, registry)

      old_swap = leftover_swap(ctx, "unsaved text")
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir, events_registry: registry)
      {:ok, 50} = BufferProcess.set_option(buffer, :auto_save_delay_ms, 50)

      :ok = adopt(buffer, old_swap, "unsaved text")

      # Auto-save would have written the file by now. The text is on the screen, not in the file.
      refute_receive {:minga_event, :buffer_saved, _event}, 400
      assert File.read!(ctx.path) == "saved text"
      assert Buffer.dirty?(buffer)

      # An edit is the user's decision about the text, and auto-save resumes from there.
      :ok = Buffer.insert_text(buffer, "edited: ")
      assert_receive {:minga_event, :buffer_saved, _event}, 5_000
      assert File.read!(ctx.path) == "edited: unsaved text"
    end

    test "a buffer with unsaved changes holds newer text and keeps both", ctx do
      old_swap = leftover_swap(ctx, "text from before the crash")
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)
      :ok = Buffer.replace_content(buffer, "typed since the restart")

      assert {:error, :modified} = adopt(buffer, old_swap, "text from before the crash")

      assert Buffer.content(buffer) == "typed since the restart"
      assert File.exists?(old_swap)
    end

    test "a read-only buffer refuses and the swap stays", ctx do
      old_swap = leftover_swap(ctx, "unsaved text")
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir, read_only: true)

      assert {:error, :read_only} = adopt(buffer, old_swap, "unsaved text")
      assert File.exists?(old_swap)
    end

    test "text the file already holds needs no swap at all", ctx do
      old_swap = leftover_swap(ctx, "saved text")
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)

      assert :ok = adopt(buffer, old_swap, "saved text")

      refute Buffer.dirty?(buffer)
      assert File.ls!(ctx.swap_dir) == []
    end

    test "a buffer that writes no swap files takes the text and removes the old swap", ctx do
      old_swap = leftover_swap(ctx, "unsaved text")
      buffer = start_buffer(ctx, [])

      assert :ok = adopt(buffer, old_swap, "unsaved text")

      assert Buffer.content(buffer) == "unsaved text"
      refute File.exists?(old_swap)
    end

    test "when its own swap cannot be written, the old swap stays", ctx do
      old_swap = leftover_swap(ctx, "unsaved text")
      # A file where the swap directory should be: every write into it fails.
      blocked_dir = Path.join(Path.dirname(ctx.swap_dir), "not-a-directory")
      File.write!(blocked_dir, "")
      buffer = start_buffer(ctx, swap_dir: blocked_dir)

      assert :ok = adopt(buffer, old_swap, "unsaved text")

      assert Buffer.content(buffer) == "unsaved text"
      assert {:ok, _meta, "unsaved text"} = Swap.read(old_swap)
    end
  end

  describe "a buffer that starts where a crashed buffer of this run kept its text" do
    test "takes the text, so its edits, its close and a quit cannot destroy it unseen", ctx do
      crashed = start_buffer(ctx, swap_dir: ctx.swap_dir)
      :ok = Buffer.replace_content(crashed, "unsaved text of the crashed buffer")
      crash(crashed)
      own_swap = Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)
      assert {:ok, _meta, "unsaved text of the crashed buffer"} = Swap.read(own_swap)

      # The user opens the file again. Nothing recovered it in between.
      reopened = start_buffer(ctx, swap_dir: ctx.swap_dir)

      assert Buffer.content(reopened) == "unsaved text of the crashed buffer"
      assert Buffer.dirty?(reopened)

      # The text is on the screen now, so giving it up is the user's decision.
      :ok = Buffer.undo(reopened)
      assert Buffer.content(reopened) == "saved text"
    end

    test "adopting the same text again keeps the swap it already owns", ctx do
      crashed = start_buffer(ctx, swap_dir: ctx.swap_dir)
      :ok = Buffer.replace_content(crashed, "unsaved text")
      crash(crashed)
      own_swap = Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)
      reopened = start_buffer(ctx, swap_dir: ctx.swap_dir)

      # The editor's crash recovery read the same swap and hands the text over.
      assert :ok = adopt(reopened, own_swap, "unsaved text")

      assert Buffer.content(reopened) == "unsaved text"
      assert {:ok, _meta, "unsaved text"} = Swap.read(own_swap)
    end

    test "a kept swap that the file already matches is removed", ctx do
      own_swap = Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)
      {:ok, prepared} = Swap.prepare(ctx.path, "saved text", swap_dir: ctx.swap_dir)
      :ok = Swap.publish(prepared)

      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)

      refute Buffer.dirty?(buffer)
      refute File.exists?(own_swap)
    end

    test "a buffer without a swap directory leaves the file alone", ctx do
      {:ok, prepared} = Swap.prepare(ctx.path, "kept text", swap_dir: ctx.swap_dir)
      :ok = Swap.publish(prepared)

      buffer = start_buffer(ctx, [])

      assert Buffer.content(buffer) == "saved text"
      assert File.exists?(Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir))
    end
  end

  describe "release_swap/1" do
    test "removes the swap file, so the next start recovers nothing", ctx do
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)
      :ok = Buffer.replace_content(buffer, "text the user chose to discard")
      write_swap_after_debounce(buffer)
      own_swap = Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)
      assert File.exists?(own_swap)

      assert :ok = BufferProcess.release_swap(buffer, ctx.swap_dir)

      refute File.exists?(own_swap)
      assert Recovery.scan(swap_dir: ctx.swap_dir, pid_alive?: fn _pid -> false end) == []
    end

    test "an edit after the release writes no new swap", ctx do
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)
      :ok = Buffer.replace_content(buffer, "first")
      :ok = BufferProcess.release_swap(buffer, ctx.swap_dir)

      # The VM is stopping, but a late edit still reaches the buffer.
      :ok = Buffer.replace_content(buffer, "late edit while the editor quits")
      write_swap_after_debounce(buffer)

      assert swap_files(ctx.swap_dir) == []
    end

    test "a buffer that writes into another directory keeps its swap", ctx do
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)
      :ok = Buffer.replace_content(buffer, "unsaved text of another editor's buffer")
      write_swap_after_debounce(buffer)

      assert :ok = BufferProcess.release_swap(buffer, Path.join(ctx.swap_dir, "elsewhere"))

      assert File.exists?(Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir))
    end

    test "a buffer that cannot answer in time keeps its swap and does not hold up the quit",
         ctx do
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)
      :ok = Buffer.replace_content(buffer, "unsaved text")
      write_swap_after_debounce(buffer)

      swap_path = Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)
      assert {:ok, _, "unsaved text"} = Recovery.read(swap_path)

      :sys.suspend(buffer)

      try do
        assert {:timeout, _call} =
                 catch_exit(BufferProcess.release_swap(buffer, ctx.swap_dir, 50))

        assert {:error, [{ctx.path, :timeout}]} == Buffer.release_swaps(ctx.swap_dir, 50)
      after
        :sys.resume(buffer)
      end

      # This ordinary call from the same sender runs after both expired releases.
      assert "unsaved text" == Buffer.content(buffer)
      assert {:ok, _, "unsaved text"} = Recovery.read(swap_path)
    end

    test "a write that was pending when the user quit is cancelled", ctx do
      buffer = start_buffer(ctx, swap_dir: ctx.swap_dir)
      :ok = Buffer.replace_content(buffer, "edited less than a debounce ago")

      assert :ok = BufferProcess.release_swap(buffer, ctx.swap_dir)
      write_swap_after_debounce(buffer)

      assert swap_files(ctx.swap_dir) == []
    end
  end

  defp start_buffer(ctx, opts) do
    start_supervised!({BufferProcess, Keyword.merge([file_path: ctx.path], opts)}, id: make_ref())
  end

  defp adopt(buffer, swap_path, content) do
    assert {:ok, source, ^content} = Recovery.read(swap_path)
    Buffer.adopt_recovered_text(buffer, content, source)
  end

  # A message no callback handles makes the buffer raise, which is a crash and not a deliberate stop.
  defp crash(buffer) do
    monitor = Process.monitor(buffer)
    send(buffer, :message_no_callback_handles)
    assert_receive {:DOWN, ^monitor, :process, ^buffer, _reason}, 2_000
  end

  # Writes the swap a crashed editor would have left for the file.
  defp leftover_swap(ctx, content) do
    opts = [swap_dir: ctx.swap_dir, os_pid: @dead_editor]
    {:ok, prepared} = Swap.prepare(ctx.path, content, opts)
    :ok = Swap.publish(prepared)
    Swap.swap_path(ctx.path, opts)
  end

  # Fires the debounce timer by hand, then waits for the write worker and its publication.
  defp write_swap_after_debounce(buffer) do
    send(buffer, :write_swap)
    :sys.get_state(buffer)

    case :sys.get_state(buffer).swap.active do
      {_snapshot, worker, _monitor} ->
        monitor = Process.monitor(worker)
        assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
        :sys.get_state(buffer)

      nil ->
        :ok
    end

    :ok
  end

  defp swap_files(swap_dir) do
    case File.ls(swap_dir) do
      {:ok, files} -> files
      {:error, :enoent} -> []
    end
  end
end

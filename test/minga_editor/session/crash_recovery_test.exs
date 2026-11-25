defmodule MingaEditor.Session.CrashRecoveryTest do
  @moduledoc "Behavior tests for reading a crashed buffer's swap file and the outcomes that leave the editor unchanged."

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import MingaEditor.RenderPipeline.TestHelpers

  alias Minga.Events.BufferCrashedEvent
  alias Minga.Session.Swap
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Session.CrashRecovery

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "notes.txt")
    File.write!(path, "saved text")
    swap_opts = [swap_dir: Path.join(dir, "swap"), os_pid: 99_999]
    %{path: path, swap_opts: swap_opts, swap_path: Swap.swap_path(path, swap_opts)}
  end

  describe "run/1" do
    test "reads the unsaved text and leaves the swap file on disk", ctx do
      :ok = Swap.write(ctx.path, "unsaved text", ctx.swap_opts)
      effect = %CrashRecovery{path: ctx.path, swap_path: ctx.swap_path}

      assert CrashRecovery.run(effect) == {:ok, {ctx.path, "unsaved text"}}
      assert File.exists?(ctx.swap_path)
    end

    test "fails when the swap file is gone", ctx do
      effect = %CrashRecovery{path: ctx.path, swap_path: ctx.swap_path}

      assert {:error, _reason} = CrashRecovery.run(effect)
    end

    test "refuses a swap file that holds another file's text", ctx do
      other = Path.join(Path.dirname(ctx.path), "other.txt")
      :ok = Swap.write(other, "other text", ctx.swap_opts)
      effect = %CrashRecovery{path: ctx.path, swap_path: Swap.swap_path(other, ctx.swap_opts)}

      assert CrashRecovery.run(effect) == {:error, {:swap_belongs_to, other}}
    end
  end

  describe "schedule/2" do
    test "does nothing for a buffer that announced no crash" do
      state = base_state(backend: :tui)

      assert CrashRecovery.schedule(state, nil) == state
    end

    test "without a scheduler the state is unchanged and the log says where the text stays",
         ctx do
      state = base_state(backend: :tui)
      crash = %BufferCrashedEvent{buffer: self(), path: ctx.path, swap_path: ctx.swap_path}

      log = capture_log(fn -> assert CrashRecovery.schedule(state, crash) == state end)

      assert log =~ ctx.path
      assert log =~ ctx.swap_path
    end
  end

  describe "apply/2" do
    test "a failed or canceled read leaves the editor unchanged and names the swap file", ctx do
      state = base_state(backend: :tui)
      effect = %CrashRecovery{path: ctx.path, swap_path: ctx.swap_path}
      request = Request.new(effect, {:crash_recovery, ctx.path}, Policy.fifo(1))

      failed = Outcome.failed(request, :enoent)
      log = capture_log(fn -> assert {^state, ^failed} = CrashRecovery.apply(state, failed) end)
      assert log =~ ctx.swap_path
      refute CrashRecovery.render?(failed)

      canceled = Outcome.canceled(request, :requested)
      assert {^state, ^canceled} = CrashRecovery.apply(state, canceled)
      refute CrashRecovery.render?(canceled)
    end

    test "a completed read asks for a render", ctx do
      effect = %CrashRecovery{path: ctx.path, swap_path: ctx.swap_path}
      request = Request.new(effect, {:crash_recovery, ctx.path}, Policy.fifo(1))

      assert CrashRecovery.render?(Outcome.completed(request, {ctx.path, "unsaved text"}))
    end
  end
end

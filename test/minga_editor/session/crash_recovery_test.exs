defmodule MingaEditor.Session.CrashRecoveryTest do
  @moduledoc "Behavior tests for reading a crashed buffer's swap file and the outcomes that leave the editor unchanged."

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import MingaEditor.RenderPipeline.TestHelpers

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events.BufferCrashedEvent
  alias Minga.Session.Swap
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Session.CrashRecovery
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

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
      effect = effect(ctx)

      path = ctx.path
      swap_path = ctx.swap_path

      assert {:ok, {%{path: ^path, swap_path: ^swap_path}, "unsaved text"}} =
               CrashRecovery.run(effect)

      assert File.exists?(ctx.swap_path)
    end

    test "fails when the swap file is gone", ctx do
      assert {:error, _reason} = CrashRecovery.run(effect(ctx))
    end

    test "refuses a swap file that holds another file's text", ctx do
      other = Path.join(Path.dirname(ctx.path), "other.txt")
      :ok = Swap.write(other, "other text", ctx.swap_opts)
      effect = %{effect(ctx) | swap_path: Swap.swap_path(other, ctx.swap_opts)}

      assert CrashRecovery.run(effect) == {:error, {:swap_belongs_to, other}}
    end
  end

  describe "schedule/2" do
    test "does nothing for a buffer that announced no crash" do
      state = base_state(backend: :tui)

      assert CrashRecovery.schedule(state, nil, true) == state
    end

    test "a buffer that crashes again after recovery is not reopened; the user is told", ctx do
      state = base_state(backend: :tui)
      crash = %BufferCrashedEvent{buffer: self(), path: ctx.path, swap_path: ctx.swap_path}

      {told, log} =
        with_log(fn -> CrashRecovery.schedule(state, {:repeated, crash}, true) end)

      assert NoticeWorkflow.message(told) =~ "notes.txt crashed again"
      assert told.workspace == state.workspace
      assert log =~ ctx.swap_path
    end

    test "without a scheduler the state is unchanged and the log says where the text stays",
         ctx do
      state = base_state(backend: :tui)
      crash = %BufferCrashedEvent{buffer: self(), path: ctx.path, swap_path: ctx.swap_path}

      log =
        capture_log(fn ->
          assert CrashRecovery.schedule(state, {:first, crash}, true) == state
        end)

      assert log =~ ctx.path
      assert log =~ ctx.swap_path
    end
  end

  describe "apply/2" do
    test "a failed or canceled read leaves the editor unchanged and names the swap file", ctx do
      state = base_state(backend: :tui)
      request = Request.new(effect(ctx), {:crash_recovery, ctx.path}, Policy.fifo(1))

      failed = Outcome.failed(request, :enoent)
      log = capture_log(fn -> assert {^state, ^failed} = CrashRecovery.apply(state, failed) end)
      assert log =~ ctx.swap_path
      refute CrashRecovery.render?(failed)

      canceled = Outcome.canceled(request, :requested)
      assert {^state, ^canceled} = CrashRecovery.apply(state, canceled)
      refute CrashRecovery.render?(canceled)
    end

    test "a delayed read cannot reopen bytes after their generation is discarded", ctx do
      review_opts = [
        incarnation: 17,
        generation: 1,
        review: %{kind: :dirty, dirty: nil, saved: nil}
      ]

      :ok = Swap.write(ctx.path, "from before the crash", ctx.swap_opts ++ review_opts)
      request = Request.new(effect(ctx), {:crash_recovery, ctx.path}, Policy.fifo(1))
      assert {:ok, result} = CrashRecovery.run(effect(ctx))
      outcome = Outcome.completed(request, result)
      :ok = File.rm(ctx.swap_path)

      buffer = start_supervised!({BufferProcess, file_path: ctx.path, swap_dir: nil})
      state = base_state(backend: :tui)
      assert {^state, ^outcome} = CrashRecovery.apply(state, outcome)
      assert Buffer.content(buffer) == "saved text"
      refute Buffer.dirty?(buffer)

      :ok = Swap.write(ctx.path, "from before the crash", ctx.swap_opts)
      assert {^state, ^outcome} = CrashRecovery.apply(state, outcome)
      assert Buffer.content(buffer) == "saved text"
      assert {:ok, _meta, "from before the crash"} = Swap.read(ctx.swap_path)
    end

    test "automatic crash recovery refuses text when the file changed after the effect read",
         ctx do
      opts = [
        incarnation: 17,
        generation: 1,
        disk_base: :crypto.hash(:sha256, "saved text"),
        review: %{kind: :dirty, dirty: nil, saved: nil}
      ]

      :ok = Swap.write(ctx.path, "unsaved earlier text", ctx.swap_opts ++ opts)
      effect = effect(ctx)
      request = Request.new(effect, {:crash_recovery, ctx.path}, Policy.fifo(1))
      assert {:ok, result} = CrashRecovery.run(effect)
      outcome = Outcome.completed(request, result)

      buffer = start_supervised!({BufferProcess, file_path: ctx.path, swap_dir: nil})
      File.write!(ctx.path, "new disk text")
      state = base_state(backend: :tui)
      assert {^state, ^outcome} = CrashRecovery.apply(state, outcome)
      assert Buffer.content(buffer) == "saved text"
      refute Buffer.dirty?(buffer)
      assert File.read!(ctx.path) == "new disk text"
      assert {:ok, _meta, "unsaved earlier text"} = Swap.read(ctx.swap_path)
    end

    test "a completed read asks for a render", ctx do
      :ok = Swap.write(ctx.path, "unsaved text", ctx.swap_opts)
      request = Request.new(effect(ctx), {:crash_recovery, ctx.path}, Policy.fifo(1))
      assert {:ok, result} = CrashRecovery.run(effect(ctx))
      assert CrashRecovery.render?(Outcome.completed(request, result))
    end
  end

  defp effect(ctx),
    do: %CrashRecovery{path: ctx.path, swap_path: ctx.swap_path, activate?: true}
end

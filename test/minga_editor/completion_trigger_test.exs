defmodule MingaEditor.CompletionTriggerTest do
  @moduledoc "Tests for CompletionTrigger: debounce fan-out to multiple LSP clients."

  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.CompletionTrigger

  describe "new/0" do
    test "returns only the tagged phase struct and generation" do
      trigger = CompletionTrigger.new()

      assert trigger == %CompletionTrigger{phase: :idle, gen: 0}
      assert Map.keys(Map.from_struct(trigger)) |> Enum.sort() == [:gen, :phase]
      assert CompletionTrigger.generation(trigger) == 0
    end
  end

  describe "maybe_trigger/3" do
    test "trigger character sends completion requests and returns typed tracking facts" do
      {:ok, buf} =
        BufferProcess.start_link(file_path: "/tmp/test_replace_trigger.ex", content: "ab")

      me = self()
      BufferProcess.move_to(buf, {0, 2})
      Minga.LSP.SyncServer.put_clients(buf, [self(), self()])

      try do
        assert {%CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1},
                [
                  {primary_ref, :primary, ^me, ^buf, version, 1, {0, 0}},
                  {secondary_ref, :secondary, ^me, ^buf, version, 1, {0, 0}}
                ]} = CompletionTrigger.maybe_trigger(CompletionTrigger.new(), ".", buf)

        assert_receive {:"$gen_cast",
                        {:async_request, "textDocument/completion", _params, _caller,
                         ^primary_ref}}

        assert_receive {:"$gen_cast",
                        {:async_request, "textDocument/completion", _params, _caller,
                         ^secondary_ref}}
      after
        Minga.LSP.SyncServer.remove_buffer(buf)
        GenServer.stop(buf)
      end
    end

    test "identifier debounce phase sends only the generation message" do
      {:ok, buf} = BufferProcess.start_link(file_path: "/tmp/test_debounce.ex", content: "")
      :ok = BufferProcess.insert_char(buf, "a")
      :ok = BufferProcess.insert_char(buf, "b")
      clients = [self()]
      version = Minga.Buffer.version(buf)
      Minga.LSP.SyncServer.put_clients(buf, clients)

      try do
        assert {%CompletionTrigger{
                  phase: {:debounced, timer, ^clients, ^buf, ^version, {0, 0}},
                  gen: 1
                }, []} = CompletionTrigger.maybe_trigger(CompletionTrigger.new(), "b", buf)

        assert is_reference(timer)
        assert_receive {:completion_debounce, 1}, 1_000
      after
        Minga.LSP.SyncServer.remove_buffer(buf)
        GenServer.stop(buf)
      end
    end
  end

  describe "flush_debounce/2" do
    test "wrong generation debounce flush sends no LSP request" do
      {:ok, buf} = BufferProcess.start_link(file_path: "/tmp/test_wrong_gen.ex", content: "ab")
      timer = Process.send_after(self(), :old_debounce, 10_000)

      trigger = %CompletionTrigger{
        phase: {:debounced, timer, [self()], buf, Minga.Buffer.version(buf), {0, 0}},
        gen: 3
      }

      assert {^trigger, []} = CompletionTrigger.flush_debounce(trigger, 2)
      refute_receive {:"$gen_cast", {:async_request, "textDocument/completion", _, _, _}}
      GenServer.stop(buf)
    end

    test "current debounce flush sends requests and returns captured origin facts" do
      {:ok, buf} =
        BufferProcess.start_link(file_path: "/tmp/test_completion.ex", content: "hello")

      me = self()
      BufferProcess.move_to(buf, {0, 5})
      version = Minga.Buffer.version(buf)
      timer = Process.send_after(self(), :old_debounce, 10_000)
      trigger = %CompletionTrigger{phase: {:debounced, timer, [me], buf, version, {0, 3}}, gen: 4}

      assert {%CompletionTrigger{phase: {:pending, {0, 3}}, gen: 4},
              [{ref, :primary, ^me, ^buf, ^version, 4, {0, 3}}]} =
               CompletionTrigger.flush_debounce(trigger, 4)

      assert_receive {:"$gen_cast",
                      {:async_request, "textDocument/completion", _params, _caller, ^ref}}

      GenServer.stop(buf)
    end

    test "newer generation makes an older debounce message inert" do
      {:ok, buf} =
        BufferProcess.start_link(file_path: "/tmp/test_stale_debounce.ex", content: "ab")

      old_timer = Process.send_after(self(), :old_debounce, 10_000)
      new_timer = Process.send_after(self(), :new_debounce, 10_000)

      trigger = %CompletionTrigger{
        phase: {:debounced, new_timer, [self()], buf, Minga.Buffer.version(buf), {0, 0}},
        gen: 6
      }

      assert {^trigger, []} = CompletionTrigger.flush_debounce(trigger, 5)
      assert Process.cancel_timer(old_timer) != false
      refute_receive {:"$gen_cast", {:async_request, "textDocument/completion", _, _, _}}
      GenServer.stop(buf)
    end
  end

  describe "dismiss/1" do
    test "clears pending state and keeps generation" do
      trigger = %CompletionTrigger{phase: {:pending, {5, 10}}, gen: 4}
      assert CompletionTrigger.dismiss(trigger) == %CompletionTrigger{phase: :idle, gen: 4}
    end

    test "clears a debounced timer phase and keeps generation" do
      timer = Process.send_after(self(), :dismissed_debounce, 10_000)

      trigger = %CompletionTrigger{
        phase: {:debounced, timer, [self()], self(), 1, {0, 0}},
        gen: 6
      }

      assert CompletionTrigger.dismiss(trigger) == %CompletionTrigger{phase: :idle, gen: 6}
      assert Process.read_timer(timer) == false
    end
  end
end

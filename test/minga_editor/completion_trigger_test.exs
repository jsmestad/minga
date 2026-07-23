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
      refute CompletionTrigger.active?(trigger)
      assert CompletionTrigger.generation(trigger) == 0
    end
  end

  describe "flush_debounce/3" do
    test "sends completion requests to multiple clients and records roles" do
      trigger = CompletionTrigger.new()

      {:ok, buf} =
        BufferProcess.start_link(file_path: "/tmp/test_completion.ex", content: "hello")

      BufferProcess.move_to(buf, {0, 5})

      result = CompletionTrigger.flush_debounce(trigger, [self(), self()], buf)

      assert %CompletionTrigger{phase: {:pending, refs_by_role, {0, 0}}, gen: 1} = result
      assert map_size(refs_by_role) == 2
      assert [{primary_ref, :primary}] = Enum.filter(refs_by_role, &match?({_ref, :primary}, &1))

      assert [{secondary_ref, :secondary}] =
               Enum.filter(refs_by_role, &match?({_ref, :secondary}, &1))

      assert_receive {:"$gen_cast",
                      {:async_request, "textDocument/completion", _params, _caller, ^primary_ref}}

      assert_receive {:"$gen_cast",
                      {:async_request, "textDocument/completion", _params, _caller,
                       ^secondary_ref}}
    end

    test "accepts a single client pid" do
      trigger = CompletionTrigger.new()
      {:ok, buf} = BufferProcess.start_link(file_path: "/tmp/test_single.ex", content: "hello")

      result = CompletionTrigger.flush_debounce(trigger, self(), buf)

      assert %CompletionTrigger{phase: {:pending, refs_by_role, {0, 0}}, gen: 1} = result
      assert [_] = Map.keys(refs_by_role)
      assert [:primary] == Map.values(refs_by_role)
    end

    test "preserves the trigger without a file path or LSP clients" do
      trigger = %CompletionTrigger{phase: :idle, gen: 3}
      {:ok, pathless_buf} = BufferProcess.start_link(content: "hello")

      {:ok, clientless_buf} =
        BufferProcess.start_link(file_path: "/tmp/test_no_clients.ex", content: "ab")

      assert CompletionTrigger.flush_debounce(trigger, self(), pathless_buf) == trigger
      assert {^trigger, nil} = CompletionTrigger.maybe_trigger(trigger, "b", clientless_buf)
      refute_receive {:"$gen_cast", {:async_request, "textDocument/completion", _, _, _}}

      GenServer.stop(pathless_buf)
      GenServer.stop(clientless_buf)
    end
  end

  describe "maybe_trigger/3" do
    test "trigger character cancels a debounce and replaces pending refs with newer batches" do
      {:ok, buf} =
        BufferProcess.start_link(file_path: "/tmp/test_replace_trigger.ex", content: "ab")

      Minga.LSP.SyncServer.put_clients(buf, [self()])
      timer = Process.send_after(self(), :old_debounce, 10_000)
      debounced = %CompletionTrigger{phase: {:debounced, timer, {0, 0}}, gen: 4}

      try do
        assert {%CompletionTrigger{phase: {:pending, first_roles, _position}, gen: 5} = pending,
                nil} = CompletionTrigger.maybe_trigger(debounced, ".", buf)

        assert [{first_ref, :primary}] = Map.to_list(first_roles)
        assert Process.read_timer(timer) == false

        assert_receive {:"$gen_cast",
                        {:async_request, "textDocument/completion", _params, _caller, ^first_ref}}

        assert {%CompletionTrigger{phase: {:pending, second_roles, _position}, gen: 6}, nil} =
                 CompletionTrigger.maybe_trigger(pending, ".", buf)

        refute Map.has_key?(second_roles, first_ref)
        assert [{second_ref, :primary}] = Map.to_list(second_roles)

        assert_receive {:"$gen_cast",
                        {:async_request, "textDocument/completion", _params, _caller, ^second_ref}}
      after
        Minga.LSP.SyncServer.remove_buffer(buf)
        GenServer.stop(buf)
      end
    end

    test "identifier debounce phase sends the existing timer message" do
      {:ok, buf} = BufferProcess.start_link(file_path: "/tmp/test_debounce.ex", content: "")
      :ok = BufferProcess.insert_char(buf, "a")
      :ok = BufferProcess.insert_char(buf, "b")
      clients = [self()]

      Minga.LSP.SyncServer.put_clients(buf, clients)

      try do
        {result, completion} = CompletionTrigger.maybe_trigger(CompletionTrigger.new(), "b", buf)

        assert completion == nil
        assert %CompletionTrigger{phase: {:debounced, timer, {0, 0}}, gen: 0} = result
        assert is_reference(timer)
        assert_receive {:completion_debounce, ^clients, ^buf}, 200
      after
        Minga.LSP.SyncServer.remove_buffer(buf)
        GenServer.stop(buf)
      end
    end
  end

  describe "dismiss/1" do
    test "clears pending refs and keeps gen" do
      primary_ref = make_ref()
      secondary_ref = make_ref()

      trigger = %CompletionTrigger{
        phase: {:pending, %{primary_ref => :primary, secondary_ref => :secondary}, {5, 10}},
        gen: 4
      }

      result = CompletionTrigger.dismiss(trigger)

      assert result == %CompletionTrigger{phase: :idle, gen: 4}

      for ref <- [primary_ref, secondary_ref] do
        assert {^result, :ignore} =
                 CompletionTrigger.classify_response(result, ref, {:ok, %{"items" => []}}, self())
      end
    end

    test "clears a debounced timer phase and keeps gen" do
      timer = Process.send_after(self(), :dismissed_debounce, 10_000)
      trigger = %CompletionTrigger{phase: {:debounced, timer, {0, 0}}, gen: 6}

      assert CompletionTrigger.dismiss(trigger) == %CompletionTrigger{phase: :idle, gen: 6}
      assert Process.read_timer(timer) == false
    end
  end

  describe "classify_response/4" do
    test "stale response is ignored without mutating pending refs" do
      ref = make_ref()
      tracked_ref = make_ref()
      trigger = %CompletionTrigger{phase: {:pending, %{tracked_ref => :primary}, {0, 0}}, gen: 0}
      {:ok, buf} = BufferProcess.start_link(content: "hello")

      assert {^trigger, :ignore} =
               CompletionTrigger.classify_response(trigger, ref, {:ok, nil}, buf)
    end

    test "error response removes only the tracked ref" do
      primary_ref = make_ref()
      secondary_ref = make_ref()

      trigger = %CompletionTrigger{
        phase: {:pending, %{primary_ref => :primary, secondary_ref => :secondary}, {0, 0}},
        gen: 2
      }

      {:ok, buf} = BufferProcess.start_link(content: "hello")

      assert {%CompletionTrigger{phase: {:pending, remaining, {0, 0}}, gen: 2} = remaining_trigger,
              :ignore} =
               CompletionTrigger.classify_response(trigger, primary_ref, {:error, "timeout"}, buf)

      assert remaining == %{secondary_ref => :secondary}

      assert {%CompletionTrigger{phase: :idle, gen: 2}, :ignore} =
               CompletionTrigger.classify_response(
                 remaining_trigger,
                 secondary_ref,
                 {:error, "timeout"},
                 buf
               )

      unknown_ref = make_ref()

      assert {^trigger, :ignore} =
               CompletionTrigger.classify_response(trigger, unknown_ref, {:error, "timeout"}, buf)
    end

    test "primary response classifies as primary and preserves secondary refs" do
      primary_ref = make_ref()
      secondary_ref = make_ref()

      trigger = %CompletionTrigger{
        phase: {:pending, %{primary_ref => :primary, secondary_ref => :secondary}, {0, 0}},
        gen: 7
      }

      {:ok, buf} = BufferProcess.start_link(content: "hello")

      assert {%CompletionTrigger{phase: {:pending, remaining, {0, 0}}, gen: 7} =
                remaining_trigger, {:primary, {0, 0}, _prefix, 7}} =
               CompletionTrigger.classify_response(
                 trigger,
                 primary_ref,
                 {:ok, %{"items" => []}},
                 buf
               )

      assert remaining == %{secondary_ref => :secondary}

      assert {%CompletionTrigger{phase: :idle, gen: 7}, {:merge, {0, 0}, _prefix, 7}} =
               CompletionTrigger.classify_response(
                 remaining_trigger,
                 secondary_ref,
                 {:ok, %{"items" => []}},
                 buf
               )
    end

    test "secondary response can arrive before primary and preserve primary ref" do
      primary_ref = make_ref()
      secondary_ref = make_ref()

      trigger = %CompletionTrigger{
        phase: {:pending, %{primary_ref => :primary, secondary_ref => :secondary}, {0, 0}},
        gen: 3
      }

      {:ok, buf} = BufferProcess.start_link(content: "hello")

      assert {%CompletionTrigger{phase: {:pending, remaining, {0, 0}}, gen: 3},
              {:merge, {0, 0}, _prefix, 3}} =
               CompletionTrigger.classify_response(
                 trigger,
                 secondary_ref,
                 {:ok, %{"items" => []}},
                 buf
               )

      assert remaining == %{primary_ref => :primary}
    end

    test "last pending response returns idle" do
      ref = make_ref()
      trigger = %CompletionTrigger{phase: {:pending, %{ref => :primary}, {0, 0}}, gen: 9}
      {:ok, buf} = BufferProcess.start_link(content: "hello")

      assert {%CompletionTrigger{phase: :idle, gen: 9}, {:primary, {0, 0}, _prefix, 9}} =
               CompletionTrigger.classify_response(trigger, ref, {:ok, %{"items" => []}}, buf)
    end
  end

  describe "generation bumping" do
    test "each request batch mints a strictly newer generation" do
      {:ok, buf} = BufferProcess.start_link(file_path: "/tmp/test_gen.ex", content: "hello")
      BufferProcess.move_to(buf, {0, 5})

      trigger0 = CompletionTrigger.new()
      trigger1 = CompletionTrigger.flush_debounce(trigger0, [self()], buf)
      trigger2 = CompletionTrigger.flush_debounce(trigger1, [self()], buf)

      assert CompletionTrigger.generation(trigger1) == CompletionTrigger.generation(trigger0) + 1
      assert CompletionTrigger.generation(trigger2) == CompletionTrigger.generation(trigger1) + 1
    end
  end
end

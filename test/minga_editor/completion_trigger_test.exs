defmodule MingaEditor.CompletionTriggerTest do
  @moduledoc "Tests for CompletionTrigger: debounce fan-out to multiple LSP clients."

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion.Session
  alias Minga.Editing.Completion.ProviderBatch
  alias MingaEditor.CompletionTrigger

  describe "new/0" do
    test "returns only the tagged phase struct and generation" do
      trigger = CompletionTrigger.new()

      assert trigger == %CompletionTrigger{phase: :idle, gen: 0}
      assert Map.keys(Map.from_struct(trigger)) |> Enum.sort() == [:gen, :phase, :session]
      assert CompletionTrigger.generation(trigger) == 0
    end
  end

  describe "maybe_trigger/4" do
    test "trigger character sends completion requests and returns typed tracking facts", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "test_replace_trigger.ex")
      File.write!(path, "ab")
      {:ok, buf} = BufferProcess.start_link(file_path: path)

      me = self()
      BufferProcess.move_to(buf, {0, 2})
      Minga.LSP.SyncServer.put_clients(buf, [self(), self()])

      try do
        assert {%CompletionTrigger{
                  phase: {:pending, {0, 2}},
                  gen: 1,
                  session: %Session{id: session_id}
                },
                [
                  {primary_ref, :primary, {:lsp_client, ^me}, ^me, ^buf, version, session_id, 1,
                   {0, 2}},
                  {secondary_ref, :secondary, {:lsp_client, ^me}, ^me, ^buf, version, session_id,
                   1, {0, 2}}
                ]} =
                 CompletionTrigger.maybe_trigger(
                   CompletionTrigger.new(),
                   ".",
                   buf,
                   Minga.Buffer.cursor_context(buf)
                 )

        assert_receive {:"$gen_cast",
                        {:async_request, "textDocument/completion", first_params, _caller,
                         ^primary_ref}}

        assert_receive {:"$gen_cast",
                        {:async_request, "textDocument/completion", second_params, _caller,
                         ^secondary_ref}}

        assert first_params["position"] == %{"line" => 0, "character" => 2}
        assert second_params["position"] == %{"line" => 0, "character" => 2}
      after
        Minga.LSP.SyncServer.remove_buffer(buf)
        GenServer.stop(buf)
      end
    end

    test "identifier debounce phase sends only the generation message", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test_debounce.ex")
      File.write!(path, "")
      {:ok, buf} = BufferProcess.start_link(file_path: path)
      :ok = BufferProcess.insert_char(buf, "a")
      :ok = BufferProcess.insert_char(buf, "b")
      clients = [self()]
      version = Minga.Buffer.version(buf)
      Minga.LSP.SyncServer.put_clients(buf, clients)

      try do
        assert {%CompletionTrigger{
                  phase: {:debounced, timer, ^clients, ^buf, ^version, {0, 0}},
                  gen: 1
                }, []} =
                 CompletionTrigger.maybe_trigger(
                   CompletionTrigger.new(),
                   "b",
                   buf,
                   Minga.Buffer.cursor_context(buf)
                 )

        assert is_reference(timer)
        assert_receive {:completion_debounce, 1}, 1_000
      after
        Minga.LSP.SyncServer.remove_buffer(buf)
        GenServer.stop(buf)
      end
    end

    test "Unicode identifiers and combining marks retain byte-indexed trigger positions", %{
      tmp_dir: tmp_dir
    } do
      text = "λe\u0301"
      path = Path.join(tmp_dir, "test_unicode.ex")
      File.write!(path, text)
      {:ok, buf} = BufferProcess.start_link(file_path: path)
      BufferProcess.move_to(buf, {0, byte_size(text)})
      Minga.LSP.SyncServer.put_clients(buf, [self()])

      try do
        assert {%CompletionTrigger{
                  phase: {:debounced, _timer, [_client], ^buf, _version, {0, 0}}
                }, []} =
                 CompletionTrigger.maybe_trigger(
                   CompletionTrigger.new(),
                   "\u0301",
                   buf,
                   Minga.Buffer.cursor_context(buf)
                 )
      after
        Minga.LSP.SyncServer.remove_buffer(buf)
        GenServer.stop(buf)
      end
    end

    test "one multibyte grapheme does not satisfy the two-grapheme debounce threshold", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "test_single_unicode.ex")
      File.write!(path, "λ")
      {:ok, buf} = BufferProcess.start_link(file_path: path)
      BufferProcess.move_to(buf, {0, byte_size("λ")})
      Minga.LSP.SyncServer.put_clients(buf, [self()])

      try do
        assert {%CompletionTrigger{phase: :idle}, []} =
                 CompletionTrigger.maybe_trigger(
                   CompletionTrigger.new(),
                   "λ",
                   buf,
                   Minga.Buffer.cursor_context(buf)
                 )
      after
        Minga.LSP.SyncServer.remove_buffer(buf)
        GenServer.stop(buf)
      end
    end

    test "typed text slices a Unicode line with internal byte positions" do
      text = "λe\u0301_value"
      {:ok, buf} = BufferProcess.start_link(content: text)
      BufferProcess.move_to(buf, {0, byte_size("λe\u0301_val")})

      assert CompletionTrigger.get_typed_since_trigger(
               Minga.Buffer.cursor_context(buf),
               {0, byte_size("λe\u0301_")}
             ) == "val"
    end

    test "trigger requests convert the byte cursor to the client's UTF-16 position", %{
      tmp_dir: tmp_dir
    } do
      text = "λ."
      path = Path.join(tmp_dir, "test_position_encoding.ex")
      File.write!(path, text)
      {:ok, buf} = BufferProcess.start_link(file_path: path)
      BufferProcess.move_to(buf, {0, byte_size(text)})
      Minga.LSP.SyncServer.put_clients(buf, [self()])

      try do
        assert {%CompletionTrigger{
                  phase: {:pending, {0, 3}},
                  session: %Session{id: session_id}
                },
                [
                  {ref, :primary, {:lsp_client, client}, client, ^buf, _version, session_id, 1,
                   {0, 3}}
                ]} =
                 CompletionTrigger.maybe_trigger(
                   CompletionTrigger.new(),
                   ".",
                   buf,
                   Minga.Buffer.cursor_context(buf)
                 )

        assert_receive {:"$gen_cast",
                        {:async_request, "textDocument/completion", params, _caller, ^ref}}

        assert params["position"] == %{"line" => 0, "character" => 2}
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

    test "current debounce flush sends requests and returns captured origin facts", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "test_completion.ex")
      File.write!(path, "hello")
      {:ok, buf} = BufferProcess.start_link(file_path: path)

      me = self()
      BufferProcess.move_to(buf, {0, 5})
      version = Minga.Buffer.version(buf)
      timer = Process.send_after(self(), :old_debounce, 10_000)
      trigger = %CompletionTrigger{phase: {:debounced, timer, [me], buf, version, {0, 3}}, gen: 4}

      assert {%CompletionTrigger{
                phase: {:pending, {0, 3}},
                gen: 4,
                session: %Session{id: session_id}
              },
              [
                {ref, :primary, {:lsp_client, ^me}, ^me, ^buf, ^version, session_id, 4, {0, 3}}
              ]} =
               CompletionTrigger.flush_debounce(trigger, 4)

      assert_receive {:"$gen_cast",
                      {:async_request, "textDocument/completion", _params, _caller, ^ref}}

      GenServer.stop(buf)
    end

    test "newer generation makes an older debounce message inert", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test_stale_debounce.ex")
      File.write!(path, "ab")
      {:ok, buf} = BufferProcess.start_link(file_path: path)

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

    test "cancels every provider request independently" do
      first_ref = make_ref()
      second_ref = make_ref()

      session =
        Session.new(make_ref(), 1, self(), 0, {0, 0})
        |> Session.register_requests([
          {:first, self(), first_ref},
          {:second, self(), second_ref}
        ])

      trigger = %CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1, session: session}

      assert CompletionTrigger.dismiss(trigger) == %CompletionTrigger{phase: :idle, gen: 1}
      assert_receive {:"$gen_cast", {:cancel_request, ^first_ref}}
      assert_receive {:"$gen_cast", {:cancel_request, ^second_ref}}
    end
  end

  describe "retrigger_incomplete/2" do
    test "uses trigger kind 3 and retains the stable session id", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test_incomplete_retrigger.ex")
      File.write!(path, "hello")
      {:ok, buf} = BufferProcess.start_link(file_path: path)
      BufferProcess.move_to(buf, {0, 5})
      context = Minga.Buffer.cursor_context(buf)
      session = Session.new(make_ref(), 1, buf, context.version, {0, 0})
      request_ref = make_ref()
      session = Session.register_requests(session, [{:provider, self(), request_ref}])

      batch =
        ProviderBatch.from_response(
          session.id,
          1,
          :provider,
          self(),
          request_ref,
          %{"isIncomplete" => true, "items" => [%{"label" => "hello"}]}
        )

      assert {:ok, session} = Session.accept_batch(session, batch)
      trigger = %CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1, session: session}

      assert {%CompletionTrigger{session: %Session{id: session_id, generation: 2}},
              [{ref, :primary, :provider, client, ^buf, version, session_id, 2, {0, 0}}]} =
               CompletionTrigger.retrigger_incomplete(trigger, context)

      assert client == self()
      assert version == context.version

      assert_receive {:"$gen_cast",
                      {:async_request, "textDocument/completion", params, _caller, ^ref}}

      assert params["context"] == %{"triggerKind" => 3}
      GenServer.stop(buf)
    end
  end
end

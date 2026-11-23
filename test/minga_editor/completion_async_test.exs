defmodule MingaEditor.CompletionAsyncTest do
  @moduledoc "Coverage for processing LSP completion responses off the Editor hot path."

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion
  alias Minga.Editing.Completion.ProviderBatch
  alias Minga.Editing.Completion.Session, as: CompletionSession
  alias MingaEditor.CompletionHandling
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.LSP, as: LSPState

  @sync_timeout 15_000

  defp items(raws), do: Completion.parse_response(%{"items" => raws})

  defp completion_from(raws, trigger_pos, prefix) do
    raws
    |> items()
    |> Completion.new(trigger_pos)
    |> Completion.filter(prefix)
  end

  defp open_completion_modal(state, completion, gen) do
    owner = state.shell_runtime.state.tab_bar.active_id
    trigger = %CompletionTrigger{gen: gen, phase: {:pending, {0, 0}}}
    payload = CompletionPayload.new(owner, completion: completion, trigger: trigger)
    ModalWorkflow.open(state, {:completion, payload})
  end

  defp labels(%Completion{filtered: filtered}), do: Enum.map(filtered, & &1.label)

  describe "(a) parse/sort/filter runs off the Editor process" do
    test "the synchronous handler leaves the menu pending and the built menu arrives async" do
      ctx = start_editor("hello")
      on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(ctx.buffer) end)
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      Minga.LSP.SyncServer.put_clients(buffer, [self()])
      version = Minga.Buffer.version(buffer)
      trigger = %CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1}
      state = ModalWorkflow.put_completion_trigger(state, trigger)

      result =
        {:ok,
         %{
           "items" => [
             %{"label" => "banana", "filterText" => "banana", "sortText" => "2"},
             %{"label" => "apple", "filterText" => "apple", "sortText" => "1"}
           ]
         }}

      returned =
        CompletionHandling.handle_completion_result(
          state,
          :primary,
          self(),
          buffer,
          version,
          1,
          {0, 0},
          result
        )

      assert MingaEditor.Shell.Traditional.ModalWorkflow.completion(returned) == nil

      assert_receive {:completion_processed, 1, :primary, %Completion{} = built, {0, 0}, ^buffer,
                      ^version},
                     @sync_timeout

      assert labels(built) == ["apple", "banana"]
    end
  end

  describe "Unicode prefix acceptance" do
    test "accept replaces the byte-indexed Unicode prefix with the selected text" do
      text = "λe\u0301_va"
      ctx = start_editor(text)
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      :ok = Minga.Buffer.move_to(buffer, {0, byte_size(text)})

      completion =
        [%{"label" => "λe\u0301_value", "insertText" => "λe\u0301_value"}]
        |> items()
        |> Completion.new({0, 0})

      _state = CompletionHandling.accept(state, completion)

      assert Minga.Buffer.content(buffer) == "λe\u0301_value"
      assert Minga.Buffer.cursor(buffer) == {0, byte_size("λe\u0301_value")}
    end

    test "accept replaces only the typed prefix and keeps the text after the cursor" do
      ctx = start_editor("fo(x)\nnext")
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      :ok = Minga.Buffer.move_to(buffer, {0, 2})

      completion =
        [%{"label" => "foo", "insertText" => "foo"}]
        |> items()
        |> Completion.new({0, 0})

      _state = CompletionHandling.accept(state, completion)

      assert Minga.Buffer.content(buffer) == "foo(x)\nnext"
      assert Minga.Buffer.cursor(buffer) == {0, 3}
    end
  end

  describe "accepting an LSP text edit" do
    test "the range end is exclusive, so the character after it is kept" do
      {buffer, _state} = accept_text_edit("    han(1)", 7, :utf16, {4, 7}, "handle")

      assert Minga.Buffer.content(buffer) == "    handle(1)"
      assert Minga.Buffer.cursor(buffer) == {0, byte_size("    handle")}
    end

    test "UTF-16 character offsets are converted to byte columns on a non-ASCII line" do
      line = "héllo 🎉 fo(x)"
      # "héllo " is 6 UTF-16 units and "🎉" is 2, so "fo" spans units 9..11 and bytes 12..14.
      {buffer, _state} =
        accept_text_edit(line, byte_size("héllo 🎉 fo"), :utf16, {9, 11}, "foo")

      assert Minga.Buffer.content(buffer) == "héllo 🎉 foo(x)"
      assert Minga.Buffer.cursor(buffer) == {0, byte_size("héllo 🎉 foo")}
    end

    test "a negotiated UTF-8 encoding reads character offsets as bytes" do
      line = "héllo 🎉 fo(x)"

      {buffer, _state} =
        accept_text_edit(line, byte_size("héllo 🎉 fo"), :utf8, {12, 14}, "foo")

      assert Minga.Buffer.content(buffer) == "héllo 🎉 foo(x)"
    end

    test "an offset inside a code point is rejected visibly and changes nothing" do
      line = "héllo 🎉 fo(x)"

      # UTF-16 unit 7 is the middle of the "🎉" surrogate pair.
      {buffer, state} = accept_text_edit(line, byte_size("héllo 🎉 fo"), :utf16, {7, 11}, "foo")

      assert Minga.Buffer.content(buffer) == line
      assert NoticeWorkflow.message(state) == "Completion failed: :column_not_boundary"
    end
  end

  describe "accepting an LSP text edit after editing since the request" do
    test "a character deleted since the request shortens the range, keeping the text after it" do
      {ctx, state} = open_text_edit_menu("    han(1)", 7, {4, 7}, "handle")

      :ok = Minga.Buffer.delete_before(ctx.buffer)
      state = CompletionHandling.maybe_handle(state, true, 127, 0)
      assert %Completion{} = completion = ModalWorkflow.completion(state)

      _state = CompletionHandling.accept(state, completion)

      assert Minga.Buffer.content(ctx.buffer) == "    handle(1)"
      assert Minga.Buffer.cursor(ctx.buffer) == {0, byte_size("    handle")}
    end

    test "characters typed since the request are replaced too" do
      {ctx, state} = open_text_edit_menu("    han(1)", 7, {4, 7}, "handle")

      :ok = Minga.Buffer.insert_text(ctx.buffer, "dl")
      state = CompletionHandling.maybe_handle(state, true, ?l, 0)

      _state = CompletionHandling.accept(state, ModalWorkflow.completion(state))

      assert Minga.Buffer.content(ctx.buffer) == "    handle(1)"
    end

    test "a server range ending past the cursor keeps its distance from the cursor" do
      # The server replaces the whole word "hanxx", which extends past the request cursor.
      {ctx, state} = open_text_edit_menu("    hanxx(1)", 7, {4, 9}, "handle")

      :ok = Minga.Buffer.insert_text(ctx.buffer, "d")
      state = CompletionHandling.maybe_handle(state, true, ?d, 0)

      _state = CompletionHandling.accept(state, ModalWorkflow.completion(state))

      assert Minga.Buffer.content(ctx.buffer) == "    handle(1)"
    end

    test "a deletion before a non-ASCII range end converts the end against the request line" do
      # "é" is one UTF-16 unit and two bytes; the request was sent after "hé".
      {ctx, state} = open_text_edit_menu("    hé(1)", byte_size("    hé"), {4, 6}, "hello")

      :ok = Minga.Buffer.delete_before(ctx.buffer)
      state = CompletionHandling.maybe_handle(state, true, 127, 0)

      _state = CompletionHandling.accept(state, ModalWorkflow.completion(state))

      assert Minga.Buffer.content(ctx.buffer) == "    hello(1)"
    end
  end

  # Opens a session-backed completion menu with one text-edit item, as if a UTF-16 LSP client had
  # answered a request sent with the cursor at `cursor_col`; the word starts at the range start.
  defp open_text_edit_menu(line, cursor_col, {start_char, end_char}, new_text) do
    ctx = start_editor(line)
    state = editor_state(ctx)
    buffer = state.workspace.buffers.active
    :ok = Minga.Buffer.move_to(buffer, {0, cursor_col})
    client = start_encoding_responder(:utf16)
    provider_id = {:lsp_client, client}
    version = Minga.Buffer.version(buffer)
    trigger_pos = {0, start_char}
    request_ref = make_ref()

    session =
      CompletionSession.new(make_ref(), 1, buffer, version, trigger_pos)
      |> CompletionSession.register_requests(
        [{provider_id, client, request_ref}],
        {{0, cursor_col}, line}
      )

    raw = %{
      "label" => new_text,
      "textEdit" => %{
        "range" => %{
          "start" => %{"line" => 0, "character" => start_char},
          "end" => %{"line" => 0, "character" => end_char}
        },
        "newText" => new_text
      }
    }

    batch =
      ProviderBatch.from_response(session.id, 1, provider_id, client, request_ref, [raw])

    {:ok, session} = CompletionSession.accept_batch(session, batch)
    completion = Completion.new(CompletionSession.index(session), trigger_pos, nil)
    trigger = CompletionTrigger.new() |> CompletionTrigger.put_session(session)
    owner = state.shell_runtime.state.tab_bar.active_id
    payload = CompletionPayload.new(owner, completion: completion, trigger: trigger)

    state =
      %{state | workspace: SessionState.transition_mode(state.workspace, :insert)}
      |> ModalWorkflow.open({:completion, payload})

    {ctx, state}
  end

  # Accepts one text-edit item from an LSP client that negotiated `encoding`, with the cursor at
  # `cursor_col` on the single line `line`.
  defp accept_text_edit(line, cursor_col, encoding, {start_char, end_char}, new_text) do
    ctx = start_editor(line)
    state = editor_state(ctx)
    buffer = state.workspace.buffers.active
    :ok = Minga.Buffer.move_to(buffer, {0, cursor_col})
    client = start_encoding_responder(encoding)

    completion =
      [
        %{
          "label" => new_text,
          "textEdit" => %{
            "range" => %{
              "start" => %{"line" => 0, "character" => start_char},
              "end" => %{"line" => 0, "character" => end_char}
            },
            "newText" => new_text
          }
        }
      ]
      |> Completion.parse_response({:lsp_client, client})
      |> Completion.new({0, start_char})

    {buffer, CompletionHandling.accept(state, completion)}
  end

  # Answers `Minga.LSP.Client.encoding/1` like a client that negotiated `encoding`.
  defp start_encoding_responder(encoding) do
    pid =
      spawn_link(fn ->
        receive_loop = fn loop ->
          receive do
            {:"$gen_call", from, :encoding} ->
              GenServer.reply(from, encoding)
              loop.(loop)
          end
        end

        receive_loop.(receive_loop)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  describe "completion updates" do
    test "one post-insert event reads one coherent cursor context" do
      ctx = start_editor("identifier")
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      :ok = Minga.Buffer.move_to(buffer, {0, byte_size("identifier")})

      workspace = SessionState.transition_mode(state.workspace, :insert)
      state = %{state | workspace: workspace}

      :erlang.trace(buffer, true, [:receive])

      try do
        _state = CompletionHandling.maybe_handle(state, true, ?r, 0)

        assert_receive {:trace, ^buffer, :receive, {:"$gen_call", _from, :cursor_context}}
        refute_receive {:trace, ^buffer, :receive, {:"$gen_call", _from, _other_call}}
      after
        :erlang.trace(buffer, false, [:receive])
      end
    end
  end

  describe "(b) stale processed result is discarded latest-wins" do
    test "a result tagged with an older generation never overwrites the live menu" do
      ctx = start_editor("hello")
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      version = Minga.Buffer.version(buffer)

      existing = completion_from([%{"label" => "keep", "filterText" => "keep"}], {0, 0}, "")
      state = open_completion_modal(state, existing, 5)

      stale =
        completion_from(
          [%{"label" => "stale-sentinel", "filterText" => "stale-sentinel"}],
          {0, 0},
          ""
        )

      discarded =
        CompletionHandling.apply_processed(state, 4, :primary, stale, {0, 0}, buffer, version)

      assert labels(MingaEditor.Shell.Traditional.ModalWorkflow.completion(discarded)) == ["keep"]

      applied =
        CompletionHandling.apply_processed(state, 5, :primary, stale, {0, 0}, buffer, version)

      assert "stale-sentinel" in labels(
               MingaEditor.Shell.Traditional.ModalWorkflow.completion(applied)
             )
    end

    test "a result is discarded when the active buffer changed even on the same generation" do
      ctx = start_editor("hello")
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      version = Minga.Buffer.version(buffer)
      existing = completion_from([%{"label" => "keep", "filterText" => "keep"}], {0, 0}, "")
      state = open_completion_modal(state, existing, 5)
      other = start_supervised!({BufferProcess, content: "other"}, id: {:buffer, make_ref()})
      stale = completion_from([%{"label" => "stale", "filterText" => "stale"}], {0, 0}, "")

      buffers = Buffers.set_active_override(state.workspace.buffers, other)
      changed = %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}

      result =
        CompletionHandling.apply_processed(changed, 5, :primary, stale, {0, 0}, buffer, version)

      assert labels(MingaEditor.Shell.Traditional.ModalWorkflow.completion(result)) == ["keep"]
    end
  end

  describe "(c) merge path still produces correct merged+filtered completions" do
    test "secondary server items are unioned in, sorted, and prefix-filtered" do
      ctx = start_editor("hello")
      BufferProcess.move_to(ctx.buffer, {0, 5})
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      version = Minga.Buffer.version(buffer)

      existing =
        completion_from(
          [%{"label" => "helloThere", "filterText" => "helloThere", "sortText" => "1"}],
          {0, 0},
          "hello"
        )

      state = open_completion_modal(state, existing, 5)

      merge_items =
        items([
          %{"label" => "helloWorld", "filterText" => "helloWorld", "sortText" => "2"},
          %{"label" => "goodbye", "filterText" => "goodbye", "sortText" => "0"}
        ])

      merged =
        CompletionHandling.apply_processed(state, 5, :merge, merge_items, {0, 0}, buffer, version)

      completion = MingaEditor.Shell.Traditional.ModalWorkflow.completion(merged)

      assert labels(completion) == ["helloThere", "helloWorld"]
      refute "goodbye" in labels(completion)
    end

    test "a primary result that lands after a secondary merge unions instead of replacing" do
      ctx = start_editor("hello")
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      version = Minga.Buffer.version(buffer)
      secondary = completion_from([%{"label" => "from_secondary"}], {0, 0}, "")
      state = open_completion_modal(state, secondary, 5)
      primary = completion_from([%{"label" => "from_primary"}], {0, 0}, "")

      merged =
        CompletionHandling.apply_processed(state, 5, :primary, primary, {0, 0}, buffer, version)

      result_labels = labels(MingaEditor.Shell.Traditional.ModalWorkflow.completion(merged))

      assert "from_secondary" in result_labels
      assert "from_primary" in result_labels
    end
  end

  describe "(d) dismissal clears completion request ownership" do
    test "dismiss drops primary and secondary completion refs while preserving unrelated refs" do
      ctx = start_editor("hello")
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      version = Minga.Buffer.version(buffer)
      completion = completion_from([%{"label" => "hello", "filterText" => "hello"}], {0, 0}, "")
      state = open_completion_modal(state, completion, 1)
      primary_ref = make_ref()
      secondary_ref = make_ref()
      signature_ref = make_ref()

      lsp =
        state.lsp
        |> LSPState.track_completion_result_request(
          primary_ref,
          :primary,
          self(),
          buffer,
          version,
          1,
          {0, 0}
        )
        |> LSPState.track_completion_result_request(
          secondary_ref,
          :secondary,
          self(),
          buffer,
          version,
          1,
          {0, 0}
        )
        |> LSPState.track_signature_help_request(signature_ref, self(), buffer, version, {0, 0})

      result = CompletionHandling.dismiss(%{state | lsp: lsp})

      refute ModalOverlay.match(result.shell_runtime.state.modal, :completion)
      assert LSPState.fetch_pending_request(result.lsp, primary_ref) == :error
      assert LSPState.fetch_pending_request(result.lsp, secondary_ref) == :error

      assert LSPState.fetch_pending_request(result.lsp, signature_ref) ==
               {:ok, {:signature_help, self(), buffer, version, {0, 0}}}
    end

    test "direct modal dismissal drops session result and resolve refs" do
      ctx = start_editor("hello")
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      version = Minga.Buffer.version(buffer)
      session_id = make_ref()
      result_ref = make_ref()
      accepted_ref = make_ref()
      resolve_ref = make_ref()
      signature_ref = make_ref()

      session =
        CompletionSession.new(session_id, 1, buffer, version, {0, 0})
        |> CompletionSession.register_requests([
          {:accepted, self(), accepted_ref},
          {:pending, self(), result_ref}
        ])

      batch =
        ProviderBatch.from_response(
          session_id,
          1,
          :accepted,
          self(),
          accepted_ref,
          %{"items" => [%{"label" => "hello"}]}
        )

      assert {:ok, session} = CompletionSession.accept_batch(session, batch)
      item = hd(CompletionSession.items(session))
      assert {:ok, session} = CompletionSession.begin_resolve(session, item.id, self(), nil)

      identity = {session_id, :accepted, item.id}
      assert {:ok, session} = CompletionSession.track_resolve(session, identity, resolve_ref)

      completion = Completion.new(CompletionSession.items(session), {0, 0})

      payload =
        CompletionPayload.new(state.shell_runtime.state.tab_bar.active_id,
          completion: completion,
          trigger: %CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1, session: session}
        )

      lsp =
        state.lsp
        |> LSPState.track_completion_result_request(
          {result_ref, :primary, :pending, self(), buffer, version, session_id, 1, {0, 0}}
        )
        |> LSPState.track_completion_resolve_request(
          {resolve_ref, self(), buffer, version, session_id, 1, :accepted, item.id, item.raw}
        )
        |> LSPState.track_signature_help_request(signature_ref, self(), buffer, version, {0, 0})

      dismissed =
        state
        |> Map.put(:lsp, lsp)
        |> ModalWorkflow.open({:completion, payload})
        |> ModalWorkflow.dismiss()

      refute ModalOverlay.match(dismissed.shell_runtime.state.modal, :completion)
      assert LSPState.fetch_pending_request(dismissed.lsp, result_ref) == :error
      assert LSPState.fetch_pending_request(dismissed.lsp, resolve_ref) == :error

      assert LSPState.fetch_pending_request(dismissed.lsp, signature_ref) ==
               {:ok, {:signature_help, self(), buffer, version, {0, 0}}}

      assert_receive {:"$gen_cast", {:cancel_request, ^result_ref}}
      assert_receive {:"$gen_cast", {:cancel_request, ^resolve_ref}}
    end
  end

  describe "(e) end-to-end through the live Editor handle_info" do
    defp inject_pending_completion(ctx, ref, client) do
      :sys.replace_state(ctx.editor, fn state ->
        owner = state.shell_runtime.state.tab_bar.active_id
        buffer = state.workspace.buffers.active
        version = Minga.Buffer.version(buffer)
        trigger = %CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1}
        payload = CompletionPayload.new(owner, trigger: trigger)

        state
        |> ModalWorkflow.open({:completion, payload})
        |> Map.update!(:lsp, fn lsp ->
          LSPState.track_completion_result_request(
            lsp,
            ref,
            :primary,
            client,
            buffer,
            version,
            1,
            {0, 0}
          )
        end)
      end)
    end

    test "a real LSP completion response routes through handle_info and becomes visible" do
      ctx = start_editor("hello")
      ref = make_ref()
      Minga.LSP.SyncServer.put_clients(ctx.buffer, [self()])
      inject_pending_completion(ctx, ref, self())

      result =
        {:ok,
         %{
           "items" => [
             %{"label" => "zeta", "filterText" => "zeta", "sortText" => "2"},
             %{"label" => "alpha", "filterText" => "alpha", "sortText" => "1"}
           ]
         }}

      send(ctx.editor, {:lsp_response, ref, result})

      final =
        wait_until(
          ctx,
          fn state ->
            match?(%Completion{}, MingaEditor.Shell.Traditional.ModalWorkflow.completion(state))
          end,
          max_attempts: 200,
          interval_ms: 10,
          message: "completion never became visible via the live Editor handle_info"
        )

      completion = MingaEditor.Shell.Traditional.ModalWorkflow.completion(final)
      assert Enum.map(completion.filtered, & &1.label) == ["alpha", "zeta"]
    end

    test "a malformed item crashes the Task but clears the stuck pending menu" do
      ctx = start_editor("hello")
      ref = make_ref()
      Minga.LSP.SyncServer.put_clients(ctx.buffer, [self()])
      inject_pending_completion(ctx, ref, self())

      send(ctx.editor, {:lsp_response, ref, {:ok, %{"items" => [nil]}}})

      _ =
        wait_until(
          ctx,
          fn state ->
            not ModalOverlay.match(
              MingaEditor.Shell.Runtime.state(state.shell_runtime).modal,
              :completion
            )
          end,
          max_attempts: 200,
          interval_ms: 10,
          message: "pending completion modal was left stuck after a Task crash"
        )

      final = editor_state(ctx)
      refute ModalOverlay.match(final.shell_runtime.state.modal, :completion)
      assert MingaEditor.Shell.Traditional.ModalWorkflow.completion(final) == nil
    end

    test "a malformed secondary merge keeps the primary batch pending" do
      ctx = start_editor("hello")
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      version = Minga.Buffer.version(buffer)

      owner = state.shell_runtime.state.tab_bar.active_id
      trigger = %CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1}
      payload = CompletionPayload.new(owner, trigger: trigger)
      state = ModalWorkflow.open(state, {:completion, payload})

      result =
        CompletionHandling.apply_processed(state, 1, :merge, :failed, {0, 0}, buffer, version)

      assert ModalOverlay.match(result.shell_runtime.state.modal, :completion)
      assert MingaEditor.Shell.Traditional.ModalWorkflow.completion(result) == nil
    end
  end

  describe "session-owned runtime path" do
    test "a routed worker result is accepted only by its exact live session request" do
      ctx = start_editor("hello")
      on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(ctx.buffer) end)
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      version = Minga.Buffer.version(buffer)
      provider_id = {:lsp_client, self()}
      request_ref = make_ref()
      session_id = make_ref()

      session =
        CompletionSession.new(session_id, 1, buffer, version, {0, 0})
        |> CompletionSession.register_requests([{provider_id, self(), request_ref}])

      trigger = %CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1, session: session}
      owner = state.shell_runtime.state.tab_bar.active_id
      payload = CompletionPayload.new(owner, trigger: trigger)

      state =
        state
        |> Map.put(:workspace, SessionState.transition_mode(state.workspace, :insert))
        |> ModalWorkflow.open({:completion, payload})

      Minga.LSP.SyncServer.put_clients(buffer, [self()])

      result =
        {:ok,
         %{
           "isIncomplete" => true,
           "items" => [%{"label" => "hello", "sortText" => "hello"}]
         }}

      fact =
        {request_ref, :primary, provider_id, self(), buffer, version, session_id, 1, {0, 0}}

      state = CompletionHandling.install_completion_tracking(state, [fact])

      {returned, [:render_now]} =
        MingaEditor.Handlers.LspEventHandler.handle(state, {:lsp_response, request_ref, result})

      assert LSPState.fetch_pending_request(returned.lsp, request_ref) == :error

      replacement_session =
        CompletionSession.register_requests(session, [{provider_id, self(), make_ref()}])

      superseded =
        ModalWorkflow.put_completion_trigger(
          returned,
          CompletionTrigger.put_session(trigger, replacement_session)
        )

      assert_receive {:completion_processed, ^fact, %ProviderBatch{} = batch}, @sync_timeout

      assert CompletionHandling.apply_processed(superseded, fact, batch) == superseded

      applied = CompletionHandling.apply_processed(returned, fact, batch)

      assert labels(ModalWorkflow.completion(applied)) == ["hello"]
      live_session = applied |> ModalWorkflow.completion_trigger() |> CompletionTrigger.session()
      assert CompletionSession.incomplete_providers(live_session) == [{provider_id, self()}]
    end

    test "complete results remain resolvable after additional prefix input" do
      ctx = start_editor("he")
      on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(ctx.buffer) end)
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      :ok = BufferProcess.move_to(buffer, {0, 2})
      version = Minga.Buffer.version(buffer)
      provider_id = {:lsp_client, self()}
      request_ref = make_ref()
      session_id = make_ref()

      session =
        CompletionSession.new(session_id, 1, buffer, version, {0, 0})
        |> CompletionSession.register_requests([{provider_id, self(), request_ref}])

      batch =
        ProviderBatch.from_response(
          session_id,
          1,
          provider_id,
          self(),
          request_ref,
          %{"items" => [%{"label" => "hello", "filterText" => "hello"}]}
        )

      assert {:ok, session} = CompletionSession.accept_batch(session, batch)

      completion =
        Completion.new(CompletionSession.items(session), {0, 0}) |> Completion.filter("he")

      payload =
        CompletionPayload.new(state.shell_runtime.state.tab_bar.active_id,
          completion: completion,
          trigger: %CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1, session: session}
        )

      state =
        state
        |> Map.put(:workspace, SessionState.transition_mode(state.workspace, :insert))
        |> ModalWorkflow.open({:completion, payload})

      Minga.LSP.SyncServer.put_clients(buffer, [self()])
      :ok = BufferProcess.insert_char(buffer, "l")

      continued = CompletionHandling.maybe_handle(state, true, ?l, 0)
      assert labels(ModalWorkflow.completion(continued)) == ["hello"]

      continued_session =
        continued |> ModalWorkflow.completion_trigger() |> CompletionTrigger.session()

      assert continued_session.id == session_id
      assert continued_session.generation == 1
      assert continued_session.buffer_version == Minga.Buffer.version(buffer)
      refute_receive {:"$gen_cast", {:async_request, "textDocument/completion", _, _, _}}, 50

      resolving = CompletionHandling.maybe_resolve_selected(continued)

      selected =
        CompletionSession.find_item(continued_session, continued_session.selected_item_id)

      resolving =
        CompletionHandling.flush_resolve(
          resolving,
          session_id,
          1,
          provider_id,
          selected.id
        )

      assert_receive {:"$gen_cast",
                      {:async_request, "completionItem/resolve", raw_item, caller, resolve_ref}}

      assert raw_item == selected.raw
      assert caller == self()

      {resolved, effects} =
        MingaEditor.Handlers.LspEventHandler.handle(
          resolving,
          {:lsp_response, resolve_ref, {:ok, %{"documentation" => "Full docs"}}}
        )

      assert effects == [:render_now]

      assert Completion.selected_item(ModalWorkflow.completion(resolved)).documentation ==
               "Full docs"
    end

    test "mode switch rejects a late provider response before background processing" do
      ctx = start_editor("hello")
      on_exit(fn -> Minga.LSP.SyncServer.remove_buffer(ctx.buffer) end)
      state = editor_state(ctx)
      buffer = state.workspace.buffers.active
      version = Minga.Buffer.version(buffer)
      provider_id = {:lsp_client, self()}
      request_ref = make_ref()
      session_id = make_ref()

      session =
        CompletionSession.new(session_id, 1, buffer, version, {0, 0})
        |> CompletionSession.register_requests([{provider_id, self(), request_ref}])

      payload =
        CompletionPayload.new(state.shell_runtime.state.tab_bar.active_id,
          trigger: %CompletionTrigger{phase: {:pending, {0, 0}}, gen: 1, session: session}
        )

      state = ModalWorkflow.open(state, {:completion, payload})
      Minga.LSP.SyncServer.put_clients(buffer, [self()])

      fact =
        {request_ref, :primary, provider_id, self(), buffer, version, session_id, 1, {0, 0}}

      returned =
        CompletionHandling.handle_completion_result(state, fact, {:ok, [%{"label" => "late"}]})

      assert returned == state
      refute_receive {:completion_processed, ^fact, _}, 50
    end
  end
end

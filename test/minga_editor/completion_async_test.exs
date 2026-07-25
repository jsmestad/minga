defmodule MingaEditor.CompletionAsyncTest do
  @moduledoc "Coverage for processing LSP completion responses off the Editor hot path."

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion
  alias MingaEditor.CompletionHandling
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.Shell.Traditional.ModalWorkflow
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
end

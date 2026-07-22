defmodule MingaEditor.CompletionAsyncTest do
  @moduledoc """
  Coverage for processing LSP completion responses off the Editor hot path
  (ticket #2633).

  The Editor only does cheap ref bookkeeping when a completion response
  arrives; the parse/sort/filter runs in a Task that sends the processed menu
  back as `{:completion_processed, gen, mode, payload, trigger_pos}`. These
  tests prove:

    * (a) the parse/sort/filter does not run on the Editor path — the
      synchronous handler leaves the menu pending and the built menu only
      arrives later, as a message, already sorted and filtered;
    * (b) a stale processed result (older generation) is discarded latest-wins
      so a superseded Task can never overwrite a fresher menu;
    * (c) the merge path still unions a secondary server's items into the live
      menu and re-applies the prefix filter correctly;
    * (d) end-to-end through the live Editor: a completion response drives the
      real `handle_info({:completion_processed, ...})` clause and the menu
      becomes visible — and a malformed item that crashes the Task clears the
      pending menu instead of leaving it stuck.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion
  alias MingaEditor.CompletionHandling
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload

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
    trigger = %CompletionTrigger{gen: gen}
    payload = CompletionPayload.new(owner, completion: completion, trigger: trigger)
    ModalWorkflow.open(state, {:completion, payload})
  end

  defp labels(%Completion{filtered: filtered}), do: Enum.map(filtered, & &1.label)

  describe "(a) parse/sort/filter runs off the Editor process" do
    test "the synchronous handler leaves the menu pending and the built menu arrives async" do
      ctx = start_editor("hello")
      state = editor_state(ctx)

      # Open a pending completion modal with a primary request in flight. `self()`
      # is the test process, so the Task will send the processed menu back to us.
      ref = make_ref()

      trigger = %CompletionTrigger{
        phase: {:pending, %{ref => :primary}, {0, 0}},
        gen: 1
      }

      state = ModalWorkflow.put_completion_trigger(state, trigger)

      # sortText is deliberately out of label order to prove sorting happened in
      # the Task, not on the Editor.
      result =
        {:ok,
         %{
           "items" => [
             %{"label" => "banana", "filterText" => "banana", "sortText" => "2"},
             %{"label" => "apple", "filterText" => "apple", "sortText" => "1"}
           ]
         }}

      returned = CompletionHandling.handle_response(state, ref, result)

      # The Editor path itself never parsed/built the menu: it is still pending.
      assert MingaEditor.Shell.Traditional.ModalWorkflow.completion(returned) == nil

      # The built menu arrives later, off-process, already sorted and filtered.
      assert_receive {:completion_processed, 1, :primary, %Completion{} = built, {0, 0}},
                     @sync_timeout

      assert labels(built) == ["apple", "banana"]
    end
  end

  describe "(b) stale processed result is discarded latest-wins" do
    test "a result tagged with an older generation never overwrites the live menu" do
      ctx = start_editor("hello")
      state = editor_state(ctx)

      existing = completion_from([%{"label" => "keep", "filterText" => "keep"}], {0, 0}, "")
      state = open_completion_modal(state, existing, 5)

      stale =
        completion_from(
          [%{"label" => "stale-sentinel", "filterText" => "stale-sentinel"}],
          {0, 0},
          ""
        )

      # Generation 4 is stale relative to the live generation 5: discard it.
      discarded = CompletionHandling.apply_processed(state, 4, :primary, stale, {0, 0})
      assert labels(MingaEditor.Shell.Traditional.ModalWorkflow.completion(discarded)) == ["keep"]

      # The same result on the live generation 5 is applied (sanity check that the
      # guard is about the generation, not the payload).
      applied = CompletionHandling.apply_processed(state, 5, :primary, stale, {0, 0})

      assert "stale-sentinel" in labels(
               MingaEditor.Shell.Traditional.ModalWorkflow.completion(applied)
             )
    end

    test "a result is discarded when the completion menu has been dismissed" do
      ctx = start_editor("hello")
      state = editor_state(ctx)

      # No completion modal is open (modal is :none), so any processed result is stale.
      built = completion_from([%{"label" => "ghost", "filterText" => "ghost"}], {0, 0}, "")
      result = CompletionHandling.apply_processed(state, 1, :primary, built, {0, 0})

      assert MingaEditor.Shell.Traditional.ModalWorkflow.completion(result) == nil
    end
  end

  describe "(c) merge path still produces correct merged+filtered completions" do
    test "secondary server items are unioned in, sorted, and prefix-filtered" do
      ctx = start_editor("hello")
      # Cursor at end of "hello" so the prefix typed since trigger {0, 0} is "hello".
      BufferProcess.move_to(ctx.buffer, {0, 5})
      state = editor_state(ctx)

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

      merged = CompletionHandling.apply_processed(state, 5, :merge, merge_items, {0, 0})
      completion = MingaEditor.Shell.Traditional.ModalWorkflow.completion(merged)

      # Union of both servers, sorted by sortText, with "goodbye" filtered out by
      # the "hello" prefix.
      assert labels(completion) == ["helloThere", "helloWorld"]
      refute "goodbye" in labels(completion)
    end

    test "a primary result that lands after a secondary merge unions instead of replacing" do
      ctx = start_editor("hello")
      state = editor_state(ctx)

      # A secondary :merge already populated the menu first.
      secondary = completion_from([%{"label" => "from_secondary"}], {0, 0}, "")
      state = open_completion_modal(state, secondary, 5)

      # The slower primary result lands afterwards; its items must be unioned in.
      primary =
        completion_from([%{"label" => "from_primary"}], {0, 0}, "")

      merged = CompletionHandling.apply_processed(state, 5, :primary, primary, {0, 0})
      result_labels = labels(MingaEditor.Shell.Traditional.ModalWorkflow.completion(merged))

      assert "from_secondary" in result_labels
      assert "from_primary" in result_labels
    end
  end

  describe "(d) end-to-end through the live Editor handle_info" do
    # Inject a pending completion modal whose bridge expects `ref`, so a real
    # {:lsp_response, ref, ...} sent to the live Editor drives the whole async
    # pipeline: handle_info -> CompletionHandling.handle_response -> Task ->
    # {:completion_processed, ...} -> the Editor's handle_info apply clause.
    defp inject_pending_completion(ctx, ref) do
      :sys.replace_state(ctx.editor, fn state ->
        owner = state.shell_runtime.state.tab_bar.active_id

        trigger = %CompletionTrigger{
          phase: {:pending, %{ref => :primary}, {0, 0}},
          gen: 1
        }

        payload = CompletionPayload.new(owner, trigger: trigger)
        ModalWorkflow.open(state, {:completion, payload})
      end)
    end

    test "a real LSP completion response routes through handle_info and becomes visible" do
      ctx = start_editor("hello")
      ref = make_ref()
      inject_pending_completion(ctx, ref)

      result =
        {:ok,
         %{
           "items" => [
             %{"label" => "zeta", "filterText" => "zeta", "sortText" => "2"},
             %{"label" => "alpha", "filterText" => "alpha", "sortText" => "1"}
           ]
         }}

      # Drive the real Editor mailbox: this exercises the actual
      # handle_info({:completion_processed, ...}) dispatch clause, which the
      # unit tests bypass by calling apply_processed/5 directly.
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
      assert %Completion{} = completion
      # Sorted in the Task (sortText order), not response order.
      assert Enum.map(completion.filtered, & &1.label) == ["alpha", "zeta"]
    end

    test "a malformed item crashes the Task but clears the stuck pending menu" do
      ctx = start_editor("hello")
      ref = make_ref()
      inject_pending_completion(ctx, ref)

      # A bare `null` in the items list FunctionClauseErrors in parse_item/1.
      # The Task must still report (with :failed) so the pending modal is
      # dismissed rather than left stuck on a never-arriving menu.
      result = {:ok, %{"items" => [nil]}}

      send(ctx.editor, {:lsp_response, ref, result})

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
  end
end

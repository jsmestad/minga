defmodule MingaEditor.RenderPipeline.InputTest do
  use ExUnit.Case, async: true

  alias Minga.Test.EffectProbe
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.UI.Panel.MessageStore

  setup do
    state = TestHelpers.base_state()
    %{state: state}
  end

  describe "from_editor_state/1" do
    test "extracts workspace fields into workspace map", %{state: state} do
      input = Input.from_editor_state(state)

      assert input.workspace.windows == state.workspace.windows
      assert input.workspace.buffers == state.workspace.buffers
      refute Map.has_key?(input.workspace, :viewport)
      assert input.terminal_viewport == state.frontend.terminal_viewport
      assert input.workspace.editing == state.workspace.editing
      assert input.highlighting == state.parser.highlighting
      assert input.workspace.file_tree == state.workspace.file_tree
      assert input.workspace.agent_ui == state.workspace.agent_ui
      assert input.workspace.document_highlights == state.workspace.document_highlights
      assert input.workspace.search == state.workspace.search
      assert input.workspace.keymap_scope == state.workspace.keymap_scope
    end

    test "extracts top-level state fields", %{state: state} do
      input = Input.from_editor_state(state)

      assert input.port_manager == state.frontend.port_manager
      assert input.theme == state.appearance.theme
      assert input.capabilities == state.frontend.capabilities
      assert input.shell_id == Runtime.id(state.shell_runtime)
      assert input.shell == Runtime.module(state.shell_runtime)
      assert input.shell_identity == Runtime.identity(state.shell_runtime)
      assert input.shell_state == Runtime.state(state.shell_runtime)
      assert input.font_registry == MingaEditor.UI.FontRegistry.new()
      assert input.message_store == state.render.message_store
      assert input.editing_model == state.interaction.editing_model
      assert input.backend == state.frontend.backend
      assert input.layout == state.render.layout
      assert input.face_override_registries == state.parser.face_override_registries
    end

    test "excludes GenServer-only fields", %{state: state} do
      input = Input.from_editor_state(state)
      input_fields = input |> Map.from_struct() |> Map.keys() |> MapSet.new()

      # These GenServer-only or Editor-owned fields must NOT be in Input
      excluded = [
        :render_correlation,
        :buffer_monitors,
        :pending_quit,
        :last_test_command,
        :session,
        :last_cursor_line,
        :buffer_add_context,
        :effect_scheduler,
        :shell_runtime
      ]

      for field <- excluded do
        refute MapSet.member?(input_fields, field),
               "Input should not include EditorState field #{inspect(field)}"
      end
    end

    test "editor state no longer owns the font registry", %{state: state} do
      refute Map.has_key?(Map.from_struct(state), :font_registry)
    end

    test "workspace field supports state.workspace.X pattern-matching", %{state: state} do
      input = Input.from_editor_state(state)

      # This is the key compatibility test: pipeline modules do
      # %{workspace: %{editing: editing}} = state
      assert %{workspace: %{editing: editing}} = input
      assert editing == state.workspace.editing
    end

    test "snapshots Git syncing as data without carrying the scheduler process", %{state: state} do
      input = Input.from_editor_state(state)
      refute input.git_syncing
      idle_scheduler = start_scheduler()
      idle_input = Input.from_editor_state(%{state | effect_scheduler: idle_scheduler})
      refute idle_input.git_syncing

      %{scheduler: scheduler, worker: worker, request: request} = start_git_syncing_activity()
      active_state = %{state | effect_scheduler: scheduler}
      active_input = Input.from_editor_state(active_state)
      assert active_input.git_syncing

      send(worker, {:release_effect, :git_syncing})
      assert_receive {:effect_result, ^scheduler, %Outcome{request: %{id: request_id}} = outcome}
      assert request_id == request.id
      assert :ok = EffectScheduler.claim(scheduler, outcome)
      assert :ok = EffectScheduler.finalize(scheduler, outcome)

      refute Input.from_editor_state(active_state).git_syncing
    end

    test "with_font_registry/2 attaches renderer-owned registry", %{state: state} do
      input = Input.from_editor_state(state)

      {_id, registry, true} =
        MingaEditor.UI.FontRegistry.get_or_register(input.font_registry, "Fira Code")

      assert Input.with_font_registry(input, registry).font_registry == registry
    end
  end

  describe "frame-local renderer transitions" do
    test "records a renderer working window without passing it through State.Windows", %{
      state: state
    } do
      input = Input.from_editor_state(state)
      id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, id)

      render_window =
        window
        |> WindowIntent.from_window()
        |> WindowIntent.materialize(%MingaEditor.Renderer.WindowCache{})

      result = Input.record_render_window(input, id, render_window)

      assert result.workspace.windows.map[id] == render_window
      assert result.workspace.windows.tree == input.workspace.windows.tree
    end

    test "records agent scroll metrics in the frame-local workspace", %{state: state} do
      input = Input.from_editor_state(state)

      result = Input.record_agent_scroll_metrics(input, 40, 10)

      assert result.workspace.agent_ui ==
               MingaEditor.Agent.UIState.record_scroll_metrics(input.workspace.agent_ui, 40, 10)
    end
  end

  describe "EditorState.reset_frontend_render_state/1" do
    test "resets frontend cursors and requests a keyframe without resetting receipt ordering", %{
      state: state
    } do
      message_store =
        state.render.message_store
        |> MessageStore.append("first", :info, :editor)
        |> MessageStore.mark_sent(1)

      state =
        %{
          state
          | render: MingaEditor.State.Render.accept_message_store(state.render, message_store)
        }

      {correlation, revision} =
        MingaEditor.State.RenderCorrelation.submit(state.render.render_correlation)

      state = %{
        state
        | render: MingaEditor.State.Render.accept_correlation(state.render, correlation)
      }

      result = EditorState.reset_frontend_render_state(state)

      assert result.render.message_store.last_sent_id == 0
      assert result.render.message_store.stream_instance == message_store.stream_instance
      assert Enum.map(result.render.message_store.entries, & &1.text) == ["first"]
      assert result.render.render_correlation.keyframe_pending?
      assert result.render.render_correlation.latest_intent_revision == revision
      assert result.workspace == state.workspace
    end
  end

  describe "cache-free render intent" do
    test "contains only semantic window carriers", %{state: state} do
      intent = Intent.from_editor_state(state, 7)

      assert intent.revision == 7
      assert intent.frame.highlighting == state.parser.highlighting
      assert Enum.all?(intent.windows, fn {_id, window} -> match?(%WindowIntent{}, window) end)

      refute Enum.any?(intent.windows, fn {_id, window} ->
               Map.has_key?(Map.from_struct(window), :render_cache)
             end)

      refute Map.has_key?(intent.frame, :caches)
      refute Map.has_key?(intent.frame, :font_registry)
    end

    test "carries Git syncing data through intent materialization and emit context", %{
      state: state
    } do
      %{scheduler: scheduler, worker: worker} = start_git_syncing_activity()
      state = %{state | effect_scheduler: scheduler}

      intent = Intent.from_editor_state(state, 7)
      assert intent.frame.git_syncing
      refute Map.has_key?(Map.from_struct(intent.frame), :effect_scheduler)

      renderer_state =
        RendererState.new(editor_pid: nil, pipeline: &MingaEditor.RenderPipeline.run/1)

      {_renderer_state, materialized} = BufferChanges.prepare(renderer_state, intent)
      assert materialized.git_syncing
      refute Map.has_key?(Map.from_struct(materialized), :effect_scheduler)
      assert Context.from_editor_state(materialized).git_syncing

      send(worker, {:release_effect, :git_syncing})
    end
  end

  describe "EditorState.integrate_renderer_receipt/2" do
    test "applies only editor-owned receipt fields and Editor has no renderer caches",
         %{state: state} do
      input = Input.from_editor_state(state)
      windows = state.workspace.windows
      focus_tree = FocusNode.new(:editor_area, {0, 0, 80, 24})

      layout = MingaEditor.Layout.compute(state)

      receipt =
        receipt(input, 10, false,
          layout: layout,
          focus_tree: focus_tree,
          click_regions: %ClickRegions{
            modeline: [{0, 1, :modeline}],
            tab_bar: [{0, 1, :tab}]
          }
        )

      result = integrate_receipt(state, receipt)

      assert result.render.layout == layout
      assert result.render.focus_tree == focus_tree
      assert result.workspace.windows == windows
      refute Map.has_key?(Map.from_struct(result), :caches)

      assert TraditionalState.click_regions(Runtime.state(result.shell_runtime)) == %ClickRegions{
               modeline: [{0, 1, :modeline}],
               tab_bar: [{0, 1, :tab}]
             }
    end

    test "fresh receipt commits renderer-computed viewport observations", %{state: state} do
      input = Input.from_editor_state(state)
      id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, id)
      viewport = MingaEditor.Viewport.put_top(window.viewport, 12)

      render_window =
        window
        |> WindowIntent.from_window()
        |> WindowIntent.materialize(%MingaEditor.Renderer.WindowCache{
          last_buf_version: window.render_cache.buffer_version
        })
        |> MingaEditor.Renderer.RenderWindow.set_viewport(viewport)

      windows = MingaEditor.State.Windows.set_map(input.workspace.windows, %{id => render_window})
      output = %{input | workspace: %{input.workspace | windows: windows}}
      receipt = MingaEditor.Renderer.RenderReceipt.from_output(output, 10, 0, 0)

      assert %MingaEditor.Renderer.WindowObservation{viewport: ^viewport} =
               receipt.window_observations[id]

      result = integrate_receipt(state, receipt)
      observed = Map.fetch!(result.workspace.windows.map, id)

      assert observed.viewport.top == 12
      assert observed.render_cache.viewport_top == 12
    end

    test "stale receipt cannot overwrite newer editor-owned transitions", %{state: state} do
      input = Input.from_editor_state(state)
      newer_layout = MingaEditor.Layout.compute(state)
      older_layout = %{newer_layout | terminal: {1, 1, 1, 1}}
      newer = receipt(input, 20, false, layout: newer_layout)
      older = receipt(input, 19, false, layout: older_layout)

      result =
        state
        |> integrate_receipt(newer)
        |> integrate_receipt(older)

      assert result.render.layout == newer_layout
      assert result.render.render_correlation.last_receipt_seq == 20
    end

    test "pending acknowledgement is stale after a newer resize/focus/shell intent", %{
      state: state
    } do
      input = Input.from_editor_state(state)

      {correlation, old_revision} =
        MingaEditor.State.RenderCorrelation.submit(state.render.render_correlation)

      state = %{
        state
        | render: MingaEditor.State.Render.accept_correlation(state.render, correlation)
      }

      old_layout = MingaEditor.Layout.compute(state)
      pending = receipt(input, 20, false, layout: old_layout, intent_revision: old_revision)

      {correlation, new_revision} =
        MingaEditor.State.RenderCorrelation.submit(state.render.render_correlation)

      state = %{
        state
        | render: MingaEditor.State.Render.accept_correlation(state.render, correlation)
      }

      changed =
        %{state | render: MingaEditor.State.Render.invalidate_layout(state.render)}

      assert new_revision == old_revision + 1
      assert integrate_receipt(changed, pending) == changed
    end

    test "receipt from a replaced shell identity is side-effect free", %{state: state} do
      input = Input.from_editor_state(state)
      stale = receipt(input, 10, false, layout: MingaEditor.Layout.compute(state))

      fake_entry = %Entry{
        id: :fake,
        source: :config,
        module: MingaEditor.Test.FakeShell,
        display_name: "Fake",
        description: "Fake shell",
        capabilities: [:gui],
        generation: 1
      }

      switched = %{
        state
        | shell_runtime:
            Runtime.activate(
              state.shell_runtime,
              fake_entry,
              %{modeline_click_regions: [], tab_bar_click_regions: []}
            )
      }

      assert integrate_receipt(switched, stale) == switched
    end

    test "renderer receipts do not consume a keyframe request before handoff", %{state: state} do
      input = Input.from_editor_state(state)

      state = %{
        state
        | render:
            MingaEditor.State.Render.accept_correlation(
              state.render,
              MingaEditor.State.RenderCorrelation.request_keyframe(
                state.render.render_correlation
              )
            )
      }

      state = integrate_receipt(state, receipt(input, 10, false))
      state = integrate_receipt(state, receipt(input, 11, true))
      assert state.render.render_correlation.keyframe_pending?
    end
  end

  describe "sync_active_window_cursor/1" do
    test "syncs cursor from buffer into active window", %{state: state} do
      # Move cursor in the buffer
      buf = state.workspace.buffers.active
      Minga.Buffer.move_to(buf, {1, 0})

      input = Input.from_editor_state(state)
      synced = Input.sync_active_window_cursor(input)

      win_id = synced.workspace.windows.active
      window = Map.get(synced.workspace.windows.map, win_id)
      assert window.cursor == {1, 0}
    end

    test "does not copy the active buffer cursor into a window showing another buffer", %{
      state: state
    } do
      original_window = Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)
      original_cursor = original_window.cursor
      {:ok, other_buf} = BufferProcess.start_link(content: "other buffer")
      :ok = Minga.Buffer.move_to(other_buf, {0, 5})

      state = %{
        state
        | workspace:
            SessionState.set_buffers(
              state.workspace,
              Buffers.add(state.workspace.buffers, other_buf)
            )
      }

      input = Input.from_editor_state(state)
      synced = Input.sync_active_window_cursor(input)

      window = Map.fetch!(synced.workspace.windows.map, synced.workspace.windows.active)
      assert window.content == original_window.content
      assert window.cursor == original_cursor
    end

    test "no-op when no active buffer", %{state: state} do
      ws = state.workspace
      state = %{state | workspace: %{ws | buffers: %{ws.buffers | active: nil}}}
      input = Input.from_editor_state(state)

      assert Input.sync_active_window_cursor(input) == input
    end
  end

  defp start_scheduler do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, name: nil}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec({EffectScheduler, task_supervisor: task_supervisor}, id: make_ref())
      )

    :ok = EffectScheduler.attach(scheduler, self())
    scheduler
  end

  defp start_git_syncing_activity do
    scheduler = start_scheduler()

    label = :git_syncing
    effect = %EffectProbe{test_pid: self(), label: label, payloads: [label], action: :wait}

    request =
      Request.new(effect, :git_syncing_resource, Policy.fifo(0), activity: :git_syncing)

    assert {:ok, _request_id, :running} = EffectScheduler.schedule(scheduler, request)
    assert_receive {:effect_started, :git_syncing, worker, [:git_syncing]}

    %{scheduler: scheduler, worker: worker, request: request}
  end

  defp integrate_receipt(state, receipt) do
    {state, _result} = EditorState.integrate_renderer_receipt(state, receipt)
    state
  end

  defp receipt(input, frame_seq, keyframe?, overrides \\ []) do
    struct!(
      MingaEditor.Renderer.RenderReceipt,
      Keyword.merge(
        [
          layout: nil,
          focus_tree: nil,
          shell_id: input.shell_id,
          shell_identity: input.shell_identity,
          click_regions: %ClickRegions{},
          frame_seq: frame_seq,
          keyframe?: keyframe?,
          render_sent_at: 0,
          intent_revision: 0
        ],
        overrides
      )
    )
  end
end

defmodule MingaEditor.Extension.SourceFinalizerEditorTest do
  @moduledoc "Editor unload-finalization coverage for source-owned picker effects."

  # Serial because source admission is projected by the global extension registry.
  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Registry, as: ExtensionRegistry
  alias Minga.Extension.Supervisor, as: ExtensionSupervisor
  alias Minga.Test.EffectProbe
  alias MingaEditor.Effect.Policy
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Extension.SourceFinalizer
  alias MingaEditor.Input
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FetchEffect

  defmodule RootPickerExtension do
    use Minga.Extension

    @unload_attempts :source_finalizer_unload_attempts

    command(:open_differently_nested_picker, "Open extension picker",
      execute: {__MODULE__, :open_picker}
    )

    editor_event_handler(__MODULE__, [:source_unload])

    @impl true
    def name, do: :finalized_picker

    @impl true
    def description, do: "Authoritative picker attribution fixture"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def init(_config), do: {:ok, %{}}

    @spec open_picker(MingaEditor.State.t()) :: MingaEditor.State.t()
    def open_picker(state) do
      MingaEditor.PickerUI.open(
        state,
        MingaEditor.Extension.SourceFinalizerEditorTest.Remote.Picker
      )
    end

    @spec handle_editor_event(
            MingaEditor.State.t(),
            MingaEditor.Extension.EventHandler.event()
          ) :: MingaEditor.Extension.EventHandler.callback_result() | :invalid_unload_return
    def handle_editor_event(state, {:source_unload, {:extension, :finalized_picker}}) do
      case Process.whereis(@unload_attempts) do
        nil ->
          apply_unload_theme(state)

        _pid ->
          case Agent.get_and_update(@unload_attempts, &{&1, &1 + 1}) do
            0 -> :invalid_unload_return
            _attempt -> apply_unload_theme(state)
          end
      end
    end

    def handle_editor_event(_state, _event), do: :not_matched

    @spec apply_unload_theme(MingaEditor.State.t()) :: {:handled, MingaEditor.State.t()}
    defp apply_unload_theme(state) do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      {:handled, MingaEditor.State.apply_theme(state, theme)}
    end
  end

  defmodule Remote.Picker do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "Differently nested extension picker"

    @impl true
    def candidates(_context), do: []

    @impl true
    def async?, do: true

    @impl true
    def async_fetch(_context) do
      receive do
        :release_differently_nested_picker ->
          {:ok, [%Item{id: :extension_item, label: "Extension item"}], %{}}
      end
    end

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state
  end

  defmodule NestedPickerOpen do
    @spec open(MingaEditor.State.t()) :: MingaEditor.State.t()
    def open(state) do
      MingaEditor.PickerUI.open(
        state,
        MingaEditor.Extension.SourceFinalizerEditorTest.Remote.Picker
      )
    end
  end

  defmodule SidebarCallback do
    @spec open(MingaEditor.State.t(), String.t(), map()) :: MingaEditor.State.t()
    def open(state, _action, _context) do
      MingaEditor.Extension.SourceFinalizerEditorTest.NestedPickerOpen.open(state)
    end
  end

  defmodule InputEventCallback do
    @behaviour MingaEditor.Input.Handler

    @impl true
    @spec handle_key(MingaEditor.State.t(), non_neg_integer(), non_neg_integer()) ::
            MingaEditor.Input.Handler.result()
    def handle_key(state, ?p, 0) do
      opened = MingaEditor.Extension.SourceFinalizerEditorTest.NestedPickerOpen.open(state)
      {:handled, opened}
    end

    def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}
  end

  defmodule BlockingSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "Extension picker"

    @impl true
    def candidates(_context), do: []

    @impl true
    def async?, do: true

    @impl true
    def async_fetch(%{picker_ui: %{context: %{test_pid: test_pid}}}) do
      send(test_pid, {:extension_picker_started, self()})

      receive do
        :release_extension_picker -> {:ok, [], %{}}
      end
    end

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state
  end

  setup_all do
    application = :minga_source_finalizer_editor_test

    spec =
      {:application, application,
       [
         description: ~c"Source finalizer editor test application",
         vsn: ~c"1.0.0",
         modules: callback_modules(),
         registered: [],
         applications: [:kernel, :stdlib]
       ]}

    assert :ok = :application.load(spec)
    assert {:ok, _started} = Application.ensure_all_started(application)

    on_exit(fn ->
      _result = Application.stop(application)
      assert :ok = Application.unload(application)
    end)

    :ok
  end

  setup do
    :ok =
      Minga.Extension.CodeLease.activate_source(
        {:extension, :finalized_picker},
        callback_modules()
      )

    :ok = ExtensionRegistry.register_module(:finalized_picker, BlockingSource, [])
    :ok = ExtensionRegistry.update(:finalized_picker, status: :running)
    on_exit(fn -> ExtensionRegistry.unregister(:finalized_picker) end)
    :ok
  end

  test "root extension callback attributes a differently nested picker and unload quiesces it" do
    :ok = ExtensionRegistry.unregister(:finalized_picker)
    :ok = ExtensionRegistry.register_module(:finalized_picker, RootPickerExtension, [])
    {:ok, entry} = ExtensionRegistry.get(:finalized_picker)

    assert {:ok, runtime} =
             ExtensionSupervisor.start_extension(
               ExtensionSupervisor,
               ExtensionRegistry,
               :finalized_picker,
               entry,
               runtime_owned_modules: callback_modules()
             )

    runtime_monitor = Process.monitor(runtime)
    ctx = start_editor("scratch", name: MingaEditor)

    :sys.replace_state(ctx.editor, fn state ->
      MingaEditor.State.apply_theme(state, MingaEditor.UI.Theme.get!(:catppuccin_mocha))
    end)

    assert :ok =
             GenServer.call(ctx.editor, {:api_execute_command, :open_differently_nested_picker})

    state = :sys.get_state(ctx.editor)
    source = {:extension, :finalized_picker}
    {:picker, payload} = state.shell_runtime.state.modal
    assert payload.picker_ui.source == Remote.Picker
    assert payload.picker_ui.callback_source == source

    scheduler = state.effect_scheduler
    scheduler_state = :sys.get_state(scheduler)
    lane = Map.fetch!(scheduler_state.lanes, {:picker_fetch, Remote.Picker})
    assert lane.running.request.source == source
    picker_worker = lane.running.task.pid
    picker_monitor = Process.monitor(picker_worker)

    unrelated_source = {:extension, :unrelated_effect}

    unrelated =
      EffectProbe.source_request(
        self(),
        :unrelated_extension_work,
        :unrelated_extension_resource,
        Policy.fifo(0),
        unrelated_source
      )

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, unrelated)

    assert_receive {:effect_started, :unrelated_extension_work, unrelated_worker,
                    [:unrelated_extension_work]}

    {:ok, running_entry} = ExtensionRegistry.get(:finalized_picker)

    assert :ok =
             ExtensionSupervisor.stop_extension(
               ExtensionSupervisor,
               ExtensionRegistry,
               :finalized_picker,
               running_entry
             )

    assert_receive {:DOWN, ^picker_monitor, :process, ^picker_worker, _reason}
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}
    refute EffectScheduler.active_source?(scheduler, source)
    assert EffectScheduler.active_source?(scheduler, unrelated_source)

    finalized_state = :sys.get_state(ctx.editor)
    assert finalized_state.shell_runtime.state.modal == :none
    assert finalized_state.appearance.theme.name == :doom_one
    assert Minga.Extension.CallbackRegistry.callbacks_for_source(:source_unload, source) == []

    assert {:error, {:source_inactive, ^source}} =
             Minga.Extension.CodeLease.admit_callback(source, RootPickerExtension, :editor_event)

    unrelated_monitor = Process.monitor(unrelated_worker)
    assert :ok = EffectScheduler.cancel_source(scheduler, unrelated_source)
    assert_receive {:DOWN, ^unrelated_monitor, :process, ^unrelated_worker, _reason}
    _barrier = :sys.get_state(ctx.editor)
  end

  test "Editor unload callback failure reaches Instance and preserves retry semantics" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end, name: :source_finalizer_unload_attempts)
    on_exit(fn -> if Process.alive?(attempts), do: Agent.stop(attempts) end)
    :ok = ExtensionRegistry.unregister(:finalized_picker)
    :ok = ExtensionRegistry.register_module(:finalized_picker, RootPickerExtension, [])
    {:ok, entry} = ExtensionRegistry.get(:finalized_picker)
    ctx = start_editor("scratch", name: MingaEditor)

    assert {:ok, runtime} =
             ExtensionSupervisor.start_extension(
               ExtensionSupervisor,
               ExtensionRegistry,
               :finalized_picker,
               entry,
               runtime_owned_modules: callback_modules()
             )

    source = {:extension, :finalized_picker}

    callback_failure =
      {:invalid_return, source, RootPickerExtension, :handle_editor_event, :invalid_unload_return}

    finalizer_failure = %{
      family: :editor_extension_unload,
      source: source,
      reason: [callback_failure]
    }

    assert {:error, {:source_quiesce_failed, ^finalizer_failure}} =
             ExtensionSupervisor.stop_extension(
               ExtensionSupervisor,
               ExtensionRegistry,
               :finalized_picker,
               entry,
               runtime_owned_modules: callback_modules()
             )

    assert {:ok, ^runtime} =
             Minga.Extension.RuntimeSupervisor.local_child(
               Minga.Extension.InstanceRegistry.via(
                 Minga.Extension.InstanceRegistry,
                 :runtime,
                 :finalized_picker
               )
             )

    assert :ok =
             ExtensionSupervisor.stop_extension(
               ExtensionSupervisor,
               ExtensionRegistry,
               :finalized_picker,
               entry,
               runtime_owned_modules: callback_modules()
             )

    _barrier = :sys.get_state(ctx.editor)
  end

  test "sidebar callback attributes nested picker work and unload cancels it" do
    {runtime, runtime_monitor} = start_picker_extension()
    ctx = start_editor("scratch", name: MingaEditor)
    source = {:extension, :finalized_picker}

    assert :ok =
             Sidebar.register(source, %{
               id: "owned_picker_sidebar",
               display_name: "Owned picker",
               action_handler: {SidebarCallback, :open}
             })

    on_exit(fn -> Sidebar.unregister_source(source) end)

    :sys.replace_state(ctx.editor, fn state ->
      Sidebar.dispatch_action(state, "owned_picker_sidebar", "open")
    end)

    {scheduler, picker_worker, picker_monitor} = assert_owned_picker(ctx, source)
    stop_picker_extension(runtime, runtime_monitor, picker_worker, picker_monitor, scheduler, ctx)
    assert Sidebar.get("owned_picker_sidebar") == nil
  end

  test "input-event callback preserves its source for nested picker work and unload cancels it" do
    {runtime, runtime_monitor} = start_picker_extension()
    ctx = start_editor("scratch", name: MingaEditor)
    source = {:extension, :finalized_picker}

    assert :ok = Input.register_handler(source, InputEventCallback, priority: -100)
    on_exit(fn -> Input.unregister_source(source) end)

    send_key_sync(ctx, ?p)

    {scheduler, picker_worker, picker_monitor} = assert_owned_picker(ctx, source)
    stop_picker_extension(runtime, runtime_monitor, picker_worker, picker_monitor, scheduler, ctx)

    refute Enum.any?(Input.surface_handler_entries(%{editing_model: Minga.Editing.Model.Vim}), fn
             {InputEventCallback, ^source} -> true
             _handler -> false
           end)
  end

  test "quiescing source denies picker admission before callback entry" do
    source = {:extension, :finalized_picker}
    {:ok, token} = Minga.Extension.CodeLease.quiesce_source(source)
    on_exit(fn -> Minga.Extension.CodeLease.complete_unload(token) end)
    state = MingaEditor.RenderPipeline.TestHelpers.base_state(rendering: :disabled)

    effect = %FetchEffect{
      source: BlockingSource,
      callback_source: source,
      context: Context.from_editor_state(state, %{test_pid: self()}),
      revision: make_ref()
    }

    assert {:error, "Extension picker fetch failed"} = FetchEffect.run(effect)
    refute_received {:extension_picker_started, _worker}
  end

  @spec callback_modules() :: [module()]
  defp callback_modules do
    [
      RootPickerExtension,
      Remote.Picker,
      BlockingSource,
      SidebarCallback,
      InputEventCallback,
      NestedPickerOpen
    ]
  end

  @spec start_picker_extension() :: {pid(), reference()}
  defp start_picker_extension do
    :ok = ExtensionRegistry.unregister(:finalized_picker)
    :ok = ExtensionRegistry.register_module(:finalized_picker, RootPickerExtension, [])
    {:ok, entry} = ExtensionRegistry.get(:finalized_picker)

    assert {:ok, runtime} =
             ExtensionSupervisor.start_extension(
               ExtensionSupervisor,
               ExtensionRegistry,
               :finalized_picker,
               entry,
               runtime_owned_modules: callback_modules()
             )

    {runtime, Process.monitor(runtime)}
  end

  @spec assert_owned_picker(map(), ContributionCleanup.contribution_source()) ::
          {pid(), pid(), reference()}
  defp assert_owned_picker(ctx, source) do
    state = :sys.get_state(ctx.editor)
    {:picker, payload} = state.shell_runtime.state.modal
    assert payload.picker_ui.source == Remote.Picker
    assert payload.picker_ui.callback_source == source

    scheduler = state.effect_scheduler
    scheduler_state = :sys.get_state(scheduler)
    lane = Map.fetch!(scheduler_state.lanes, {:picker_fetch, Remote.Picker})
    assert lane.running.request.source == source
    picker_worker = lane.running.task.pid

    {scheduler, picker_worker, Process.monitor(picker_worker)}
  end

  @spec stop_picker_extension(
          pid(),
          reference(),
          pid(),
          reference(),
          pid(),
          map()
        ) :: :ok
  defp stop_picker_extension(
         runtime,
         runtime_monitor,
         picker_worker,
         picker_monitor,
         scheduler,
         ctx
       ) do
    {:ok, running_entry} = ExtensionRegistry.get(:finalized_picker)

    assert :ok =
             ExtensionSupervisor.stop_extension(
               ExtensionSupervisor,
               ExtensionRegistry,
               :finalized_picker,
               running_entry
             )

    assert_receive {:DOWN, ^picker_monitor, :process, ^picker_worker, _reason}
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}
    refute EffectScheduler.active_source?(scheduler, {:extension, :finalized_picker})
    assert :sys.get_state(ctx.editor).shell_runtime.state.modal == :none
    :ok
  end

  test "config reload command finalizes extension picker work through the real loader boundary" do
    test_pid = self()
    :ok = ExtensionRegistry.unregister(:finalized_picker)
    :ok = ExtensionRegistry.register_module(:finalized_picker, RootPickerExtension, [])
    {:ok, entry} = ExtensionRegistry.get(:finalized_picker)

    {:ok, _extension} =
      ExtensionSupervisor.start_extension(
        ExtensionSupervisor,
        ExtensionRegistry,
        :finalized_picker,
        entry,
        runtime_owned_modules: callback_modules()
      )

    :ok =
      ContributionCleanup.register(:zz_source_finalizer_boundary_test, fn source ->
        send(test_pid, {:cleanup_reached, source})
        :ok
      end)

    on_exit(fn -> ContributionCleanup.unregister(:zz_source_finalizer_boundary_test) end)

    # A new Editor generation must refresh this persistent callback rather than
    # retaining generation-specific routing from an old Editor.
    :ok =
      ContributionCleanup.register(:editor_effects, fn _source ->
        {:error, :stale_editor_generation}
      end)

    ctx = start_editor("scratch", name: MingaEditor)
    source = {:extension, :finalized_picker}
    other_source = {:extension, :unrelated_effect}

    state =
      :sys.replace_state(ctx.editor, fn state ->
        picker = Picker.new([], title: BlockingSource.title())

        picker_state =
          PickerState.loading(
            picker,
            BlockingSource,
            source,
            state.workspace.buffers.active_index,
            state.appearance.theme,
            %{test_pid: test_pid},
            :bottom
          )

        {picker_state, revision} = PickerState.begin_fetch(picker_state)
        send(test_pid, {:picker_revision, revision})
        ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
      end)

    assert_receive {:picker_revision, revision}
    scheduler = state.effect_scheduler

    picker_request =
      FetchEffect.request(
        BlockingSource,
        source,
        Context.from_editor_state(state, %{test_pid: self()}),
        revision
      )

    unrelated =
      EffectProbe.source_request(
        self(),
        :unrelated_reload,
        :unrelated_reload_resource,
        Policy.fifo(0),
        other_source
      )

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, picker_request)
    assert_receive {:extension_picker_started, picker_worker}
    picker_monitor = Process.monitor(picker_worker)
    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, unrelated)

    assert_receive {:effect_started, :unrelated_reload, unrelated_worker, [:unrelated_reload]}

    assert :ok = GenServer.call(ctx.editor, {:api_execute_command, :reload_config})

    assert_receive {:cleanup_reached, ^source}, 5_000
    assert_receive {:DOWN, ^picker_monitor, :process, ^picker_worker, _reason}
    refute EffectScheduler.active_source?(scheduler, source)
    assert EffectScheduler.active_source?(scheduler, other_source)
    assert :sys.get_state(ctx.editor).shell_runtime.state.modal == :none

    assert_receive {:cleanup_reached, :config}
    assert :error = ExtensionRegistry.get(:finalized_picker)

    assert :ok = EffectScheduler.cancel_source(scheduler, other_source)
    unrelated_monitor = Process.monitor(unrelated_worker)
    assert_receive {:DOWN, ^unrelated_monitor, :process, ^unrelated_worker, _reason}
    _barrier = :sys.get_state(ctx.editor)
  end

  test "source quiescence prevents pending and claimed spy candidates from applying" do
    Enum.each([:pending, :claimed], fn candidate_state ->
      ctx = start_editor("scratch")
      scheduler = :sys.get_state(ctx.editor).effect_scheduler
      source = {:extension, :quiesced_spy}

      request =
        EffectProbe.source_request(
          self(),
          candidate_state,
          {:quiesced_spy, candidate_state},
          Policy.fifo(0),
          source
        )

      :sys.suspend(ctx.editor)

      try do
        assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, request)
        assert_receive {:effect_started, ^candidate_state, worker, [^candidate_state]}
        worker_monitor = Process.monitor(worker)
        send(worker, {:release_effect, candidate_state})
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}

        outcome = await_pending_outcome(scheduler, request.id)

        if candidate_state == :claimed do
          assert :ok = EffectScheduler.claim(scheduler, outcome)
        end

        assert :ok = EffectScheduler.cancel_source(scheduler, source)
      after
        :sys.resume(ctx.editor)
      end

      _barrier = :sys.get_state(ctx.editor)
      refute_received {:effect_applied, ^candidate_state, _status}
    end)
  end

  test "unload waits for blocked picker cancellation and preserves unrelated work" do
    ctx = start_editor("scratch")
    source = {:extension, :finalized_picker}
    other_source = {:extension, :unrelated_effect}
    test_pid = self()

    state =
      :sys.replace_state(ctx.editor, fn state ->
        picker = Picker.new([], title: BlockingSource.title())

        picker_state =
          PickerState.loading(
            picker,
            BlockingSource,
            source,
            state.workspace.buffers.active_index,
            state.appearance.theme,
            %{test_pid: test_pid},
            :bottom
          )

        {picker_state, revision} = PickerState.begin_fetch(picker_state)
        send(test_pid, {:picker_revision, revision})
        ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
      end)

    assert_receive {:picker_revision, revision}
    scheduler = state.effect_scheduler

    picker_request =
      FetchEffect.request(
        BlockingSource,
        source,
        Context.from_editor_state(state, %{test_pid: self()}),
        revision
      )

    unrelated =
      EffectProbe.source_request(
        self(),
        :unrelated,
        :unrelated_resource,
        Policy.fifo(0),
        other_source
      )

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, picker_request)
    assert_receive {:extension_picker_started, picker_worker}
    picker_monitor = Process.monitor(picker_worker)
    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, unrelated)
    assert_receive {:effect_started, :unrelated, unrelated_worker, [:unrelated]}

    assert :ok = SourceFinalizer.unregister_source(source, ctx.editor)
    assert_receive {:DOWN, ^picker_monitor, :process, ^picker_worker, _reason}
    refute EffectScheduler.active_source?(scheduler, source)
    assert EffectScheduler.active_source?(scheduler, other_source)

    finalized_state = :sys.get_state(ctx.editor)
    assert finalized_state.shell_runtime.state.modal == :none

    assert :ok = EffectScheduler.cancel_source(scheduler, other_source)
    unrelated_monitor = Process.monitor(unrelated_worker)
    assert_receive {:DOWN, ^unrelated_monitor, :process, ^unrelated_worker, _reason}
    _barrier = :sys.get_state(ctx.editor)
  end

  @spec await_pending_outcome(pid(), reference()) :: MingaEditor.Effect.Outcome.t()
  defp await_pending_outcome(scheduler, request_id) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_await_pending_outcome(scheduler, request_id, deadline)
  end

  @spec do_await_pending_outcome(pid(), reference(), integer()) ::
          MingaEditor.Effect.Outcome.t()
  defp do_await_pending_outcome(scheduler, request_id, deadline) do
    case :sys.get_state(scheduler).pending do
      %{^request_id => outcome} ->
        outcome

      _pending ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            1 -> do_await_pending_outcome(scheduler, request_id, deadline)
          end
        else
          flunk("effect candidate did not become pending")
        end
    end
  end
end

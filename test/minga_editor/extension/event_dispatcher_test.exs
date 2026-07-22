defmodule MingaEditor.Extension.EventDispatcherTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias MingaEditor.Extension.EventDispatcher
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Frontend
  alias MingaEditor.Test.ExtensionEventHandlerOne, as: HandlerOne
  alias MingaEditor.Test.ExtensionEventHandlerThree, as: HandlerThree
  alias MingaEditor.Test.ExtensionEventHandlerTwo, as: HandlerTwo

  setup do
    registry = unique_name(:callback_registry)
    admission = unique_name(:callback_admission)
    generation = unique_name(:callback_generation)
    persistence_key = {__MODULE__, make_ref()}
    code_lease = unique_name(:callback_code_admission)

    start_supervised!({CallbackRegistry, name: registry})

    start_supervised!(
      {ArtifactGenerationState, name: generation, persistence_key: persistence_key}
    )

    start_supervised!({ArtifactAdmission, name: admission, state_owner: generation})
    start_supervised!({CodeLease, name: code_lease})

    on_exit(fn -> ArtifactGenerationState.reset_for_test(persistence_key) end)

    state = %EditorState{
      frontend: %Frontend{port_manager: nil},
      workspace: %SessionState{}
    }

    %{registry: registry, admission: admission, code_lease: code_lease, state: state}
  end

  test "buffer save fan-out threads successful state in deterministic priority order", ctx do
    Process.put({HandlerTwo, :callback}, fn current_state, _event ->
      updated_state = EditorState.apply_theme(current_state, MingaEditor.UI.Theme.get!(:doom_one))
      send(self(), {:higher_state, updated_state})
      {:handled, updated_state}
    end)

    Process.put({HandlerOne, :callback}, fn current_state, _event ->
      send(self(), {:higher_state_seen, current_state})
      {:handled, current_state}
    end)

    source =
      register_handlers(ctx, [
        {HandlerOne, [:buffer_saved], [priority: 10]},
        {HandlerTwo, [:buffer_saved], [priority: 20]}
      ])

    event = {:buffer_saved, self()}

    assert {:handled, updated_state} =
             EventDispatcher.dispatch(ctx.state, event, ctx.registry, ctx.code_lease)

    assert_receive {:extension_handler_called, HandlerTwo, ^event}
    assert_receive {:extension_handler_called, HandlerOne, ^event}
    assert_receive {:higher_state, higher_state}
    assert_receive {:higher_state_seen, ^higher_state}
    assert updated_state == higher_state
    assert CodeLease.active_leases(server: ctx.code_lease, source: source) == []
  end

  test "buffer save preserves earlier state, reports a later failure, and continues", ctx do
    Process.put({HandlerTwo, :callback}, fn current_state, _event ->
      updated_state = EditorState.apply_theme(current_state, MingaEditor.UI.Theme.get!(:doom_one))
      send(self(), {:earlier_state, updated_state})
      {:handled, updated_state}
    end)

    Process.put({HandlerOne, :callback}, fn _state, _event -> raise "later failure" end)

    source =
      register_handlers(ctx, [
        {HandlerTwo, [:buffer_saved], [priority: 30]},
        {HandlerOne, [:buffer_saved], [priority: 20]},
        {HandlerThree, [:buffer_saved], [priority: 10]}
      ])

    event = {:buffer_saved, self()}

    assert {:callback_failed, [failure], updated_state} =
             EventDispatcher.dispatch(ctx.state, event, ctx.registry, ctx.code_lease)

    assert {:callback_failed, ^source, HandlerOne, :handle_editor_event, :exception, _} = failure
    assert_receive {:earlier_state, ^updated_state}
    assert_receive {:extension_handler_called, HandlerTwo, ^event}
    assert_receive {:extension_handler_called, HandlerOne, ^event}
    assert_receive {:extension_handler_called, HandlerThree, ^event}
  end

  test "editor action advances only after a successful decline", ctx do
    Process.put({HandlerOne, :callback}, fn _state, _event -> :not_matched end)

    register_handlers(ctx, [
      {HandlerOne, [:editor_action], [priority: 20]},
      {HandlerTwo, [:editor_action], [priority: 10]}
    ])

    event = {:editor_action, :open, %{}}
    state = ctx.state

    assert {:handled, ^state} =
             EventDispatcher.dispatch(ctx.state, event, ctx.registry, ctx.code_lease)

    assert_receive {:extension_handler_called, HandlerOne, ^event}
    assert_receive {:extension_handler_called, HandlerTwo, ^event}
  end

  test "failed higher-priority editor action stops without falling through", ctx do
    Process.put({HandlerOne, :callback}, fn _state, _event -> throw(:action_failed) end)

    source =
      register_handlers(ctx, [
        {HandlerOne, [:editor_action], [priority: 20]},
        {HandlerTwo, [:editor_action], [priority: 10]}
      ])

    event = {:editor_action, :open, %{}}

    assert {:callback_failed,
            {:callback_failed, ^source, HandlerOne, :handle_editor_event, :throw, :action_failed}} =
             EventDispatcher.dispatch(ctx.state, event, ctx.registry, ctx.code_lease)

    assert_receive {:extension_handler_called, HandlerOne, ^event}
    refute_receive {:extension_handler_called, HandlerTwo, ^event}
  end

  test "invalid event returns are explicit failures and stop first-match dispatch", ctx do
    Process.put({HandlerOne, :callback}, fn _state, _event -> {:handled, :invalid_state} end)

    source =
      register_handlers(ctx, [
        {HandlerOne, [:editor_action], [priority: 20]},
        {HandlerTwo, [:editor_action], [priority: 10]}
      ])

    assert {:callback_failed,
            {:invalid_return, ^source, HandlerOne, :handle_editor_event,
             %{kind: :tuple, size: 2, tag: :handled}}} =
             EventDispatcher.dispatch_editor_action(
               ctx.state,
               :invalid,
               nil,
               ctx.registry,
               ctx.code_lease
             )

    refute_receive {:extension_handler_called, HandlerTwo, _event}
  end

  test "source unload preserves successful state, reports failures, and continues", ctx do
    Process.put({HandlerTwo, :callback}, fn current_state, _event ->
      updated_state = EditorState.apply_theme(current_state, MingaEditor.UI.Theme.get!(:doom_one))
      send(self(), {:unload_state, updated_state})
      {:handled, updated_state}
    end)

    Process.put({HandlerOne, :callback}, fn _state, _event -> exit(:unload_failed) end)

    source =
      register_handlers(ctx, [
        {HandlerTwo, [:source_unload], [priority: 30]},
        {HandlerOne, [:source_unload], [priority: 20]},
        {HandlerThree, [:source_unload], [priority: 10]}
      ])

    {:ok, token} = CodeLease.quiesce_source(source, server: ctx.code_lease)

    assert {:error, [failure], updated_state} =
             EventDispatcher.dispatch_source_unload(
               ctx.state,
               source,
               token,
               ctx.registry,
               ctx.code_lease
             )

    assert {:callback_failed, ^source, HandlerOne, :handle_editor_event, :exit, :unload_failed} =
             failure

    assert_receive {:unload_state, ^updated_state}
    assert_receive {:extension_handler_called, HandlerTwo, {:source_unload, ^source}}
    assert_receive {:extension_handler_called, HandlerOne, {:source_unload, ^source}}
    assert_receive {:extension_handler_called, HandlerThree, {:source_unload, ^source}}
  end

  test "quiescing source rejection does not enter the callback or leak admission", ctx do
    source = register_handlers(ctx, [{HandlerOne, [:editor_action], []}])
    {:ok, _token} = CodeLease.quiesce_source(source, server: ctx.code_lease)

    assert {:callback_failed, {:source_unavailable, ^source, HandlerOne, _, _}} =
             EventDispatcher.dispatch_editor_action(
               ctx.state,
               :blocked,
               nil,
               ctx.registry,
               ctx.code_lease
             )

    refute_receive {:extension_handler_called, HandlerOne, _event}
    assert CodeLease.active_leases(server: ctx.code_lease, source: source) == []
  end

  test "core callback failures and invalid returns propagate directly", ctx do
    Process.put({HandlerOne, :callback}, fn _state, _event -> raise "core defect" end)

    assert_raise RuntimeError, "core defect", fn ->
      EventDispatcher.dispatch_core(ctx.state, {:editor_action, :core, nil}, HandlerOne)
    end

    Process.put({HandlerOne, :callback}, fn _state, _event -> {:handled, :invalid_state} end)

    assert_raise ArgumentError, ~r/core event callback returned invalid value/, fn ->
      EventDispatcher.dispatch_core(ctx.state, {:editor_action, :core, nil}, HandlerOne)
    end
  end

  defp register_handlers(ctx, schema) do
    name = unique_name(:event_source)
    source = {:extension, name}
    modules = schema |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    {:ok, claim} =
      ArtifactAdmission.claim_source_modules(
        source,
        modules,
        :crypto.hash(:sha256, inspect({source, modules})),
        server: ctx.admission,
        trusted_application: :minga
      )

    :ok = ArtifactAdmission.commit_attempt(claim, server: ctx.admission)
    :ok = CodeLease.activate_source(source, modules, server: ctx.code_lease)

    :ok =
      CallbackRegistry.register_extension(name, schema,
        registry: ctx.registry,
        artifact_admission: ctx.admission
      )

    source
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end

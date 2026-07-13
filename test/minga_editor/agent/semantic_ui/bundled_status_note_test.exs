defmodule MingaEditor.Agent.SemanticUI.BundledStatusNoteTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.ContributionCleanup
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Text
  alias MingaEditor.Agent.SemanticUI.BundledStatusNote
  alias MingaEditor.Agent.SemanticUI.Registry
  alias MingaEditor.Editing
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  setup do
    table = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    start_supervised!({Registry, name: table, notify: self()})
    %{table: table}
  end

  test "declares a bundled transcript enrichment with editor action metadata" do
    assert BundledStatusNote.source() == {:bundle, :agent_status_note}
    assert BundledStatusNote.entry_id() == "agent-status-note"

    assert [entry] = BundledStatusNote.entries()
    assert entry.id == "agent-status-note"
    assert entry.surface == :transcript_enrichment
    assert entry.payload == {:system, "Agent UI registry online", :info}
    assert [%{id: "open_agent", editor_action: :toggle_agentic_view}] = entry.actions
  end

  test "starts as a bundled registrar and publishes transcript rendering data", %{table: table} do
    start_supervised!(
      {BundledStatusNote,
       name: Module.concat(__MODULE__, "Note#{System.unique_integer([:positive])}"),
       registry: table}
    )

    assert %MingaEditor.Agent.SemanticUI.Entry{source: {:bundle, :agent_status_note}} =
             Registry.get(table, BundledStatusNote.entry_id())

    assert_receive {:agent_semantic_ui_changed, ^table}

    assert [{message_id, {:system, "Agent UI registry online", :info}}] =
             Registry.transcript_enrichments(table)

    assert is_integer(message_id) and message_id > 0
  end

  test "dispatches semantic actions through the editor command pipeline", %{table: table} do
    :ok =
      Registry.register(table, {:bundle, :test_status}, %{
        id: "test-status",
        surface: :transcript_enrichment,
        payload: {:system, "test", :info},
        actions: [
          %{
            id: "choose_register",
            label: "Choose register",
            editor_action: {:select_register, "a"}
          }
        ]
      })

    state =
      Registry.dispatch_action(table, base_state(table), "test-status", "choose_register", %{
        button: :mouse
      })

    assert Editing.active_register(state) == "a"
  end

  test "source cleanup removes snapshots and action handlers and reload restores them", %{
    table: table
  } do
    :ok = BundledStatusNote.register(table)
    assert [_note] = Registry.transcript_enrichments(table)

    assert :ok = Registry.unregister_source(table, BundledStatusNote.source())
    assert Registry.transcript_enrichments(table) == []

    state = base_state(table)

    assert Registry.dispatch_action(table, state, BundledStatusNote.entry_id(), "open_agent", %{}) ==
             state

    assert :ok = BundledStatusNote.reload(table)
    assert [_note] = Registry.transcript_enrichments(table)
  end

  test "rejects callback handlers so semantic actions stay code-lease free", %{table: table} do
    assert {:error, {:unsupported, :handler}} =
             Registry.register(table, {:extension, :leased_action}, %{
               id: "leased-action",
               surface: :dashboard_section,
               payload: [%Text{text: "bad"}],
               actions: [%{id: "callback", label: "Callback", handler: fn -> :ok end}]
             })
  end

  test "cleanup is scoped to the semantic registry and leaves core agent state alone", %{
    table: table
  } do
    state = base_state(table)

    cleanup_state =
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        state,
        "approval and transcript state stay core-owned"
      )

    :ok = BundledStatusNote.register(table)

    assert :ok =
             ContributionCleanup.unregister_source(BundledStatusNote.source(),
               callbacks: %{agent_semantic_ui_registry: &Registry.unregister_source(table, &1)}
             )

    assert Registry.transcript_enrichments(table) == []

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(cleanup_state) ==
             "approval and transcript state stay core-owned"
  end

  defp base_state(table) do
    %EditorState{
      port_manager: self(),
      agent_semantic_ui_registry: table,
      workspace: %SessionState{viewport: Viewport.new(24, 80)}
    }
  end
end

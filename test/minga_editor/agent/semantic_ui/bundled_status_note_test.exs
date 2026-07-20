defmodule MingaEditor.Agent.SemanticUI.BundledStatusNoteTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.ContributionCleanup
  alias Minga.RenderModel.UI.Action
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Text
  alias MingaEditor.Agent.SemanticUI.BundledStatusNote
  alias MingaEditor.Agent.SemanticUI.Entry
  alias MingaEditor.Agent.SemanticUI.Registry
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

    assert %{
             id: "agent-status-note",
             surface: :transcript_enrichment,
             target: :agent_chat,
             priority: 10,
             payload: {:system, "Agent UI registry online", :info},
             actions: [action]
           } = entry

    assert action.id == "open_agent"
    assert action.label == "Open agent panel"
    assert action.kind == :primary
    assert action.editor_action == :toggle_agentic_view
    assert action.payload == %{source: "agent-status-note"}
  end

  test "default registry seeds the bundled transcript enrichment" do
    assert %Entry{
             source: {:bundle, :agent_status_note},
             id: "agent-status-note",
             actions: [%Action{id: "open_agent"}]
           } = Registry.get(Registry.default_table(), BundledStatusNote.entry_id())
  end

  test "source cleanup removes enrichments and actions", %{table: table} do
    source = BundledStatusNote.source()
    entries = BundledStatusNote.entries()

    :ok = Registry.register_many(table, source, entries)
    assert [_note] = Registry.transcript_enrichments(table)

    assert :ok = Registry.unregister_source(table, source)
    assert Registry.transcript_enrichments(table) == []

    state = base_state(table)

    assert Registry.dispatch_action(table, state, BundledStatusNote.entry_id(), "open_agent", %{}) ==
             state
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

  test "contribution cleanup unregisters the bundled semantic source", %{table: table} do
    :ok = Registry.register_many(table, BundledStatusNote.source(), BundledStatusNote.entries())

    assert :ok =
             ContributionCleanup.unregister_source(BundledStatusNote.source(),
               callbacks: %{agent_semantic_ui_registry: &Registry.unregister_source(table, &1)}
             )

    assert Registry.transcript_enrichments(table) == []
  end

  defp base_state(table) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      extension_surfaces: %MingaEditor.State.ExtensionSurfaces{agent_semantic_ui_registry: table},
      workspace: %SessionState{viewport: Viewport.new(24, 80)}
    }
  end
end

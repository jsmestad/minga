defmodule MingaEditor.Agent.SemanticUI.RegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Manifest
  alias Minga.RenderModel.UI.Action
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.Board
  alias Minga.RenderModel.UI.ExtensionPanel
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Text
  alias MingaEditor.Agent.SemanticUI.Entry
  alias MingaEditor.Agent.SemanticUI.Registry
  alias MingaEditor.RenderModel.UI.BoardBuilder
  alias MingaEditor.RenderModel.UI.ExtensionPanelBuilder

  setup do
    table = Module.concat(__MODULE__, "Table#{System.unique_integer([:positive])}")
    start_supervised!({Registry, name: table, notify: false})
    %{table: table}
  end

  test "registers render-model payloads by semantic surface", %{table: table} do
    card = board_card(101, :working)
    text = %Text{text: "agent note"}
    panel = panel("agent-panel", [text])

    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "status",
               surface: :status_card,
               payload: card,
               priority: 20
             })

    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "note",
               surface: :transcript_enrichment,
               payload: {:system, "from extension", :info},
               priority: 10
             })

    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "dash",
               surface: :dashboard_section,
               payload: [text],
               priority: 30
             })

    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "panel",
               surface: :panel,
               payload: panel,
               priority: 40
             })

    assert Registry.status_cards(table) == [card]

    assert [{message_id, {:system, "from extension", :info}}] =
             Registry.transcript_enrichments(table)

    assert is_integer(message_id) and message_id > 0

    assert Enum.map(Registry.panels(table), & &1.panel_id) == [
             "agent-panel",
             "agent-dashboard-dash"
           ]
  end

  test "rejects duplicate entry ids from another source", %{table: table} do
    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "status",
               surface: :status_card,
               payload: board_card(1, :idle)
             })

    assert {:error, {:duplicate_agent_ui_id, "status", {:extension, :alpha}}} =
             Registry.register(table, {:extension, :beta}, %{
               id: "status",
               surface: :status_card,
               payload: board_card(2, :done)
             })
  end

  test "allows owning source to publish cached payloads and actions", %{table: table} do
    source = {:extension, :alpha}

    assert :ok =
             Registry.register(table, source, %{
               id: "status",
               surface: :status_card,
               payload: board_card(1, :idle)
             })

    assert :ok =
             Registry.publish(table, source, "status", board_card(1, :done), [
               %{id: "open", label: "Open", kind: :primary, payload: %{row: 1}}
             ])

    assert %Entry{
             payload: %Board.Card{status: :done},
             actions: [%Action{id: "open", payload: %{row: 1}}]
           } = Registry.get(table, "status")
  end

  test "source cleanup removes cached payloads and pending action metadata", %{table: table} do
    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "status",
               surface: :status_card,
               payload: board_card(1, :working),
               actions: [%{id: "open", label: "Open", editor_action: :agent_dismiss_or_noop}]
             })

    assert :ok =
             Registry.register(table, {:extension, :beta}, %{
               id: "other",
               surface: :status_card,
               payload: board_card(2, :idle)
             })

    assert :ok = Registry.unregister_source(table, {:extension, :alpha})

    assert Registry.get(table, "status") == nil
    assert %Entry{id: "other"} = Registry.get(table, "other")
    assert %{} = Registry.dispatch_action(table, %{}, "status", "open", %{})
  end

  test "rejects callback action handlers in semantic metadata", %{table: table} do
    handler = fn state, _context -> state end

    assert {:error, {:unsupported, :handler}} =
             Registry.register(table, {:extension, :alpha}, %{
               id: "status",
               surface: :status_card,
               payload: board_card(42, :working),
               actions: [%{id: "open", label: "Open", handler: handler}]
             })
  end

  test "dispatches declarative actions only through explicit registry dispatch", %{table: table} do
    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "panel",
               surface: :panel,
               payload: panel("agent-panel", [%Text{text: "cached"}]),
               actions: [
                 %{
                   id: "refresh",
                   label: "Refresh",
                   payload: %{source_payload: true}
                 }
               ]
             })

    assert [%ExtensionPanel.Panel{panel_id: "agent-panel"}] = Registry.panels(table)
    assert %{} = Registry.dispatch_action(table, %{}, "panel", "refresh", %{explicit: true})
  end

  test "render builders read cached registry values without invoking callbacks", %{table: table} do
    card = board_card(77, :needs_you)

    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "status",
               surface: :status_card,
               payload: card,
               actions: [%{id: "open", label: "Open"}]
             })

    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "panel",
               surface: :panel,
               payload: panel("agent-panel", [%Text{text: "cached panel"}]),
               actions: [%{id: "refresh", label: "Refresh"}]
             })

    board =
      BoardBuilder.build({:board, %Board{visible?: true, cards: [board_card(1, :idle)]}}, table)

    extension_panel = ExtensionPanelBuilder.build(table)

    assert Enum.map(board.cards, & &1.id) == [1, 77]
    assert Enum.map(extension_panel.panels, & &1.panel_id) == ["agent-panel"]
  end

  test "extension contribution events register manifest semantic UI metadata", %{table: table} do
    manifest = %Manifest{
      name: :semantic_ui_extension,
      version: "1.0.0",
      source: :module,
      agent_ui_metadata: [
        %{id: "note", surface: :transcript_enrichment, payload: {:system, "from manifest", :info}}
      ]
    }

    send(
      Process.whereis(table),
      {:minga_event, :extension_agent_contributions_started,
       %{source: {:extension, :alpha}, manifest: manifest}}
    )

    :sys.get_state(table)

    assert [{_id, {:system, "from manifest", :info}}] = Registry.transcript_enrichments(table)
  end

  test "transcript enrichments are existing AgentChat message bodies", %{table: table} do
    view = %AgentChat.ToolCallView{
      name: "read_file",
      summary: "README.md",
      result: "",
      status: :complete,
      is_error: false
    }

    assert :ok =
             Registry.register(table, {:extension, :alpha}, %{
               id: "tool-note",
               surface: :transcript_enrichment,
               payload: {:tool_call, view}
             })

    assert [{_id, {:tool_call, ^view}}] = Registry.transcript_enrichments(table)

    assert {:error, {:invalid_payload, :transcript_enrichment}} =
             Registry.register(table, {:extension, :alpha}, %{
               id: "bad",
               surface: :transcript_enrichment,
               payload: {:custom, "not a render model"}
             })

    assert {:error, {:invalid_payload, :transcript_enrichment}} =
             Registry.register(table, {:extension, :alpha}, %{
               id: "bad-styled",
               surface: :transcript_enrichment,
               payload: {:styled_assistant, [["not a styled run"]]}
             })
  end

  defp board_card(id, status) do
    %Board.Card{
      id: id,
      status: status,
      kind: :agent,
      task: "Task #{id}",
      display_task: "Task #{id}",
      created_at: DateTime.utc_now()
    }
  end

  defp panel(id, content) do
    %ExtensionPanel.Panel{
      extension: "agent-extension",
      panel_id: id,
      title: "Agent Panel",
      position: :right,
      size: {:percent, 30},
      visible?: true,
      content: content
    }
  end
end

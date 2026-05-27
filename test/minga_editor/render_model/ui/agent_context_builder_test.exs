defmodule MingaEditor.RenderModel.UI.AgentContextBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.AgentContextBuilder
  alias Minga.RenderModel.UI.AgentContext
  alias MingaEditor.Frontend.Protocol.GUI.BoardPayload
  alias MingaEditor.Frontend.Protocol.GUI.BoardCardPayload

  describe "build/1" do
    test "returns hidden when payload is nil" do
      model = AgentContextBuilder.build(nil)

      assert %AgentContext{visible: false} = model
    end

    test "returns hidden when payload is unsupported" do
      model = AgentContextBuilder.build({:unknown, %{}})

      assert %AgentContext{visible: false} = model
    end

    test "returns hidden when board has no zoomed card" do
      board = %BoardPayload{
        visible?: true,
        cards: [],
        zoomed_card_id: nil
      }

      model = AgentContextBuilder.build({:board, board})

      assert %AgentContext{visible: false} = model
    end

    test "returns hidden when zoomed card is a you card" do
      card = %BoardCardPayload{
        id: 1,
        status: :idle,
        kind: :you,
        task: "My workspace",
        display_task: "My workspace",
        created_at: DateTime.utc_now()
      }

      board = %BoardPayload{
        visible?: true,
        cards: [card],
        zoomed_card_id: 1
      }

      model = AgentContextBuilder.build({:board, board})

      assert %AgentContext{visible: false} = model
    end

    test "returns visible context for agent card" do
      ts = ~U[2024-01-15 10:30:00Z]

      card = %BoardCardPayload{
        id: 42,
        status: :working,
        kind: :agent,
        task: "Fix the build",
        display_task: "Fix the build",
        created_at: ts
      }

      board = %BoardPayload{
        visible?: true,
        cards: [card],
        zoomed_card_id: 42
      }

      model = AgentContextBuilder.build({:board, board})

      assert %AgentContext{visible: true} = model
      assert model.task == "Fix the build"
      assert model.dispatch_timestamp == ts
      assert model.status == :working
      assert model.can_approve == false
    end

    test "sets can_approve for needs_you status" do
      card = %BoardCardPayload{
        id: 42,
        status: :needs_you,
        kind: :agent,
        task: "Review needed",
        display_task: "Review needed",
        created_at: DateTime.utc_now()
      }

      board = %BoardPayload{
        visible?: true,
        cards: [card],
        zoomed_card_id: 42
      }

      model = AgentContextBuilder.build({:board, board})

      assert model.can_approve == true
    end

    test "sets can_approve for done status" do
      card = %BoardCardPayload{
        id: 42,
        status: :done,
        kind: :agent,
        task: "Completed",
        display_task: "Completed",
        created_at: DateTime.utc_now()
      }

      board = %BoardPayload{
        visible?: true,
        cards: [card],
        zoomed_card_id: 42
      }

      model = AgentContextBuilder.build({:board, board})

      assert model.can_approve == true
    end

    test "does not set can_approve for working status" do
      card = %BoardCardPayload{
        id: 42,
        status: :working,
        kind: :agent,
        task: "Working",
        display_task: "Working",
        created_at: DateTime.utc_now()
      }

      board = %BoardPayload{
        visible?: true,
        cards: [card],
        zoomed_card_id: 42
      }

      model = AgentContextBuilder.build({:board, board})

      assert model.can_approve == false
    end
  end
end

defmodule MingaEditor.RenderModel.UI.AgentContextBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Design.Tokens
  alias Minga.Frontend.Adapter.GUI.{AgentContextEncoder, Caches}
  alias Minga.RenderModel.UI.AgentContext
  alias Minga.RenderModel.UI.AgentContext.Todo
  alias MingaAgent.TodoItem
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.Events, as: AgentEvents
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.WorkspaceStatus
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.AgentContextBuilder
  alias MingaEditor.RenderModel.UI.TabBarBuilder
  alias MingaEditor.RenderModel.UI.WorkspacesBuilder
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace

  @spec approval(String.t()) :: Public.t()
  defp approval(tool_call_id) do
    Public.new(
      Target.new("context-fixture", "admitted-request", tool_call_id),
      "shell",
      %{"command" => "mix test"},
      Preview.new(:args, "", [])
    )
  end

  describe "build/1" do
    test "unavailable chat does not display retained tool activity as live" do
      activity = Activity.start_tool(Activity.new(), "call-before-switch", "shell", %{})

      ui =
        UIState.new()
        |> UIState.replace_activity(activity)
        |> UIState.transition_chat(:unavailable)

      ctx = context(ui, %TraditionalState{})

      refute AgentContextBuilder.visible?(ctx)
      assert %AgentContext{visible: false} = AgentContextBuilder.build(ctx)
    end

    test "tool approval keeps attention without offering unrelated task review actions" do
      todo = %TodoItem{id: "1", description: "Run tests", status: :in_progress}

      activity =
        Activity.new()
        |> Activity.set_todos([todo])
        |> Activity.start_turn(~U[2026-06-23 12:00:00Z])
        |> Activity.start_tool("call-1", "shell", %{"command" => "mix test"})
        |> Activity.record_file(nil, "lib/a.ex", "/p/lib/a.ex")

      agent_ui = UIState.replace_activity(UIState.new(), activity)

      agent =
        %AgentState{}
        |> AgentState.set_status(:tool_executing)
        |> AgentState.set_pending_approval(PendingApproval.new(self(), approval("tc")))

      ctx =
        context(
          agent_ui,
          TraditionalState.replace_agent(%TraditionalState{}, agent)
        )

      assert %AgentContext{
               visible: true,
               task: "Asking to run `mix test`",
               status: :needs_you,
               can_approve: false,
               todos: [%Todo{description: "Run tests", status: :in_progress}],
               progress: %{
                 active_action: "Asking to run `mix test`",
                 tool_count: 1,
                 file_count: 1,
                 review_hint: ""
               }
             } = AgentContextBuilder.build(ctx)
    end

    test "with a file in front, an approval the conversation had when it left is not shown as pending" do
      session = self()

      {tab_bar, workspace} =
        Tab.new_file(1, "manual.ex") |> TabBar.new() |> TabBar.add_workspace("Agent", session)

      # The approval was answered after the conversation left the front; its Session works again.
      tab_bar = TabBar.set_workspace_agent_status(tab_bar, workspace.id, :tool_executing)

      copy =
        %AgentState{}
        |> AgentState.apply_session_snapshot(
          session,
          :tool_executing,
          approval("tc"),
          nil,
          "shell"
        )

      shell =
        %TraditionalState{}
        |> TraditionalState.install_tab_bar(tab_bar)
        |> TraditionalState.replace_agent(copy)

      # Before, the strip said "Awaiting approval for shell" beside a working status.
      assert %AgentContext{
               status: :iterating,
               task: "Running tools",
               progress: %{active_action: ""}
             } = AgentContextBuilder.build(context(UIState.new(), shell))
    end

    test "a running tool reads on the card as its step reads in the conversation" do
      for {name, args} <- [
            {"read_file", %{"path" => "./notes.txt"}},
            {"shell", %{"command" => "mix test"}},
            {"grep", %{"pattern" => "TODO", "path" => "lib"}},
            {"lsp_diagnostics", %{}}
          ] do
        activity =
          Activity.new()
          |> Activity.start_turn(~U[2026-06-23 12:00:00Z])
          |> Activity.start_tool("call-1", name, args)

        agent = AgentState.set_status(%AgentState{}, :tool_executing)

        ctx =
          context(
            UIState.replace_activity(UIState.new(), activity),
            TraditionalState.replace_agent(%TraditionalState{}, agent)
          )

        step = Minga.RenderModel.UI.AgentChat.ToolStep.sentence(name, args, :running)
        card = AgentContextBuilder.build(ctx)

        assert {card.task, card.progress.active_action} == {step, step}
        refute step =~ "_", "#{name} reached the user as a raw tool name"
      end
    end

    test "idle with unfinished activity does not imply completed work" do
      todo = %TodoItem{id: "unfinished", description: "Run verification", status: :in_progress}
      activity = Activity.set_todos(Activity.new(), [todo])
      agent_ui = UIState.replace_activity(UIState.new(), activity)
      agent = AgentState.set_status(%AgentState{}, :idle)
      ctx = context(agent_ui, TraditionalState.replace_agent(%TraditionalState{}, agent))

      assert %AgentContext{
               visible: true,
               status: :idle,
               todos: [%Todo{status: :in_progress}]
             } = AgentContextBuilder.build(ctx)
    end

    test "an error without recorded activity has no elapsed time and is sent only once" do
      agent = AgentState.set_status(%AgentState{}, :error)
      ctx = context(UIState.new(), TraditionalState.replace_agent(%TraditionalState{}, agent))

      assert %AgentContext{visible: true, status: :errored, dispatch_timestamp: nil} =
               first = AgentContextBuilder.build(ctx)

      assert {<<0x88, _size::16, 1, task_size::16, _task::binary-size(task_size), 0::64, 5,
                _rest::binary>>, caches} = AgentContextEncoder.encode(first, Caches.new())

      assert {nil, ^caches} =
               ctx |> AgentContextBuilder.build() |> AgentContextEncoder.encode(caches)
    end

    test "a failed start needs the user and reads its headline then its cause" do
      agent = AgentState.set_status(%AgentState{}, :error)
      shell = TraditionalState.replace_agent(%TraditionalState{}, agent)
      request = MingaEditor.Agent.StartRequest.default()

      for {failure, task} <- [
            {MingaEditor.Agent.StartFailure.timed_out(request), "Agent could not start"},
            {MingaEditor.Agent.StartFailure.missing_credentials(), "Agent needs setup"},
            {MingaEditor.Agent.StartFailure.session_crashed(self()), "Agent session stopped"}
          ] do
        ui = UIState.fail_start(UIState.new(), failure)

        assert %AgentContext{
                 visible: true,
                 status: :needs_you,
                 task: ^task,
                 progress: %{active_action: action}
               } = AgentContextBuilder.build(context(ui, shell))

        # The card reads the failure's own headline, the same one the chat
        # notice shows, then its cause, never the headline twice.
        assert task == failure.headline
        assert action == failure.message
      end
    end

    test "approval-only visible context keeps the dispatch timestamp stable" do
      approval = approval("tc-approval")

      state =
        TestHelpers.base_state(backend: :gui)
        |> AgentEvents.dispatch(self(), {:approval_pending, approval})

      started_at = state.workspace.agent_ui.view.activity.started_at
      assert started_at != nil

      ctx =
        context(
          state.workspace.agent_ui,
          TraditionalState.replace_agent(
            %TraditionalState{},
            MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
          )
        )

      first = AgentContextBuilder.build(ctx)
      second = AgentContextBuilder.build(ctx)

      assert first.visible
      assert first.status == :needs_you
      assert first.dispatch_timestamp == started_at
      assert second.dispatch_timestamp == started_at
      assert first.dispatch_timestamp == second.dispatch_timestamp
    end
  end

  describe "the workspace pill and the activity strip" do
    test "agree that a session errored while its workspace shows a file tab" do
      # The workspace payload still holds the last status an event wrote; the
      # error lives only on the live shell presentation cache.
      errored = AgentState.set_status(%AgentState{}, :error)
      ctx = agent_workspace_context(errored, UIState.new(), active_tab: 3, stored_status: :idle)

      assert workspace_status(ctx) == :error
      assert agent_tab_status(ctx) == :error
      assert %AgentContext{visible: true, status: :errored} = AgentContextBuilder.build(ctx)
    end

    test "agree that a failed start needs the user while its workspace shows a file tab" do
      failure =
        MingaEditor.Agent.StartFailure.timed_out(MingaEditor.Agent.StartRequest.default())

      failed_ui = UIState.fail_start(UIState.new(), failure)
      errored = AgentState.set_status(%AgentState{}, :error)
      ctx = agent_workspace_context(errored, failed_ui, active_tab: 3, stored_status: :error)

      assert workspace_status(ctx) == :needs_you
      assert agent_tab_status(ctx) == :needs_you
      assert %AgentContext{visible: true, status: :needs_you} = AgentContextBuilder.build(ctx)
    end

    test "agree, with the status bar and chat header, that a pending question needs the user" do
      {:ok, question} = MingaAgent.Question.new("Which file?", ["a.ex", "b.ex"])

      target = %MingaAgent.Question.Target{
        session_id: "pill-fixture",
        request_id: "request",
        checkpoint_id: "checkpoint",
        tool_call_id: "tool-call"
      }

      asking =
        %AgentState{}
        |> AgentState.set_status(:thinking)
        |> AgentState.project_question(self(), {target, question})

      ctx =
        agent_workspace_context(asking, UIState.new(), active_tab: 3, stored_status: :thinking)

      assert workspace_status(ctx) == :needs_you
      assert agent_tab_status(ctx) == :needs_you
      assert %AgentContext{visible: true, status: :needs_you} = AgentContextBuilder.build(ctx)

      # The status bar and the chat header read the active workspace's status here.
      assert MingaEditor.Agent.WorkspaceStatus.active(
               ctx.intent.frame.shell_state,
               ctx.workspace.agent_ui
             ) ==
               :needs_you
    end

    test "speak, with the status bar and chat header, the state the token table gives each status" do
      # The card names a running tool iterating only to say what the working state is doing.
      card_states = %{
        working: [:working],
        iterating: [:working],
        needs_you: [:needs_you],
        errored: [:failed],
        done: [:done],
        stopped: [:stopped],
        idle: [nil]
      }

      # Live statuses come from an attached session; stored ones from a detached workspace,
      # such as one restored from a saved session.
      live = [:idle, :thinking, :tool_executing, :error, :plan]
      stored = [:approval_waiting, :stopped, :needs_review, :done]

      for status <- live ++ stored do
        ctx =
          if status in live do
            agent_workspace_context(AgentState.set_status(%AgentState{}, status), UIState.new(),
              active_tab: 2,
              stored_status: status
            )
          else
            agent_workspace_context(%AgentState{}, UIState.new(),
              active_tab: 2,
              stored_status: status,
              session: nil
            )
          end

        # The workspace pill, the status bar and the chat header read one status and
        # name it through the token table, in Elixir, Swift and Go alike.
        assert workspace_status(ctx) == status

        assert WorkspaceStatus.active(ctx.intent.frame.shell_state, ctx.workspace.agent_ui) ==
                 status

        expected = Tokens.agent_status_state(status)
        # A hidden card shows no status at all.
        case AgentContextBuilder.build(ctx) do
          %AgentContext{visible: true, status: card} ->
            assert expected in Map.fetch!(card_states, card),
                   "#{status} shows #{card} on the card"

          %AgentContext{visible: false} ->
            :ok
        end
      end
    end

    test "a background Agent workspace shows its stored status, not the live cache" do
      ctx =
        agent_workspace_context(%AgentState{}, UIState.new(),
          active_tab: 1,
          stored_status: :error
        )

      assert workspace_status(ctx) == :error
      refute AgentContextBuilder.visible?(ctx)
    end
  end

  # Tabs: 1 is a manual file, 2 the Agent chat and 3 a file, both in Agent workspace 1.
  defp agent_workspace_context(agent, agent_ui, opts) do
    workspace =
      Workspace.new_agent(1, "Agent", Keyword.get(opts, :session, self()))
      |> Workspace.set_agent_status(Keyword.fetch!(opts, :stored_status))

    tab_bar = %TabBar{
      tabs: [
        Tab.new_file(1, "manual.ex"),
        2 |> Tab.new_agent("Agent") |> Tab.set_group(1),
        3 |> Tab.new_file("agent.ex") |> Tab.set_group(1)
      ],
      active_id: Keyword.fetch!(opts, :active_tab),
      next_id: 4,
      workspaces: [workspace],
      next_workspace_id: 2
    }

    shell_state =
      %TraditionalState{}
      |> TraditionalState.install_tab_bar(tab_bar)
      |> TraditionalState.replace_agent(agent)

    %{context(agent_ui, shell_state) | tab_bar: tab_bar}
  end

  defp workspace_status(ctx) do
    ctx
    |> WorkspacesBuilder.build()
    |> Map.fetch!(:workspaces)
    |> Enum.find(&(&1.id == 1))
    |> Map.fetch!(:status)
  end

  defp agent_tab_status(ctx) do
    ctx
    |> TabBarBuilder.build()
    |> Map.fetch!(:tabs)
    |> Enum.find(&(&1.id == 2))
    |> Map.fetch!(:agent_status)
  end

  defp context(agent_ui, shell_state) do
    ctx =
      TestHelpers.base_state(port_manager: nil)
      |> Context.from_editor_state()

    workspace = %{ctx.workspace | agent_ui: agent_ui}
    frame = %{ctx.intent.frame | shell_state: shell_state}

    %{ctx | workspace: workspace, intent: %{ctx.intent | frame: frame, workspace: workspace}}
  end
end

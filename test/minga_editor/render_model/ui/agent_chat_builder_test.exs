defmodule MingaEditor.RenderModel.UI.AgentChatBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState
  alias Minga.Editing.Scroll
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.AgentChatBuilder
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window

  test "build/1 sends cached display message pairs to GUI agent chat" do
    session = fake_session_pid()
    old_message = {:assistant, "old pinned"}
    hidden_message = {:user, "hidden"}
    visible_message = {:assistant, "visible"}
    message_ids = [{101, old_message}, {102, hidden_message}, {103, visible_message}]

    %{display_messages: display_messages, display_message_pairs: display_pairs} =
      Transcript.display([old_message, hidden_message, visible_message],
        display_start_index: 2,
        message_ids: message_ids,
        pinned_ids: MapSet.new([101])
      )

    panel = %Panel{
      cached_display_messages: display_messages,
      cached_display_message_pairs: display_pairs,
      cached_styled_messages: [nil, nil, nil, nil]
    }

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert model.visible?

    summaries = Enum.map(model.messages, &message_summary/1)

    assert [
             {101, :assistant, "old pinned"},
             {_, :system, "── pinned ──"},
             {_, :system, "── 2 earlier messages hidden ──"},
             {103, :assistant, "visible"},
             {_, :system, "Agent UI registry online"}
           ] = summaries

    refute {:user, "hidden"} in Enum.map(summaries, fn {_id, type, text} -> {type, text} end)
  end

  test "build/1 emits only messages through the manual semantic scroll viewport" do
    session = fake_session_pid()

    panel = %Panel{
      scroll: Scroll.new(2) |> Scroll.update_metrics(5, 1),
      cached_line_index: [
        {0, :text},
        {0, :empty},
        {1, :text},
        {1, :empty},
        {2, :text}
      ],
      cached_display_message_pairs: [
        {1, {:assistant, "first"}},
        {2, {:assistant, "second"}},
        {3, {:assistant, "third"}}
      ],
      cached_styled_messages: [nil, nil, nil]
    }

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert Enum.map(model.messages, &message_summary/1) == [
             {1, :assistant, "first"},
             {2, :assistant, "second"}
           ]
  end

  defp message_summary({id, {:assistant, text}}), do: {id, :assistant, text}
  defp message_summary({id, {:system, text, _level}}), do: {id, :system, text}
  defp message_summary({id, {:user, text}}), do: {id, :user, text}
  defp message_summary({id, {kind, _, _}}), do: {id, kind, nil}

  defp context(session, panel) do
    tab = Tab.new_agent(1, "Agent") |> Tab.set_session(session)
    {tab_bar, workspace} = TabBar.add_workspace(TabBar.new(tab), "Agent", session)
    tab_bar = TabBar.move_tab_to_workspace(tab_bar, tab.id, workspace.id)
    window = Window.new_agent_chat(1, 24, 80)

    %Context{
      port_manager: self(),
      capabilities: nil,
      theme: nil,
      font_registry: nil,
      windows: %Windows{map: %{1 => window}, active: 1},
      layout: nil,
      shell: Traditional,
      shell_state: %TraditionalState{agent: %AgentState{}, tab_bar: tab_bar},
      agent_ui: %UIState{panel: panel},
      viewport: Viewport.new(24, 80),
      editing: VimState.new()
    }
  end

  defp fake_session_pid do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end
end

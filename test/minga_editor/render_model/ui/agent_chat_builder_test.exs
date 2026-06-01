defmodule MingaEditor.RenderModel.UI.AgentChatBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.BufferSync
  alias MingaEditor.Agent.UIState
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
    buffer = BufferSync.start_buffer()

    {_line_index, display_messages, display_pairs} =
      BufferSync.sync(buffer, [old_message, hidden_message, visible_message],
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
      context(buffer, session, panel)
      |> AgentChatBuilder.build()

    summaries = decode_message_summaries(model.encoded)

    assert [
             {101, :assistant, "old pinned"},
             {_, :system, "── pinned ──"},
             {_, :system, "── 2 earlier messages hidden ──"},
             {103, :assistant, "visible"}
           ] = summaries

    refute {:user, "hidden"} in Enum.map(summaries, fn {_id, type, text} -> {type, text} end)
  end

  defp context(buffer, session, panel) do
    tab = Tab.new_agent(1, "Agent") |> Tab.set_session(session)
    {tab_bar, workspace} = TabBar.add_workspace(TabBar.new(tab), "Agent", session)
    tab_bar = TabBar.move_tab_to_workspace(tab_bar, tab.id, workspace.id)
    window = Window.new_agent_chat(1, buffer, 24, 80)

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

  defp decode_message_summaries(<<0x78, _section_count::8, sections::binary>>) do
    sections
    |> gui_agent_chat_section!(0x06)
    |> unwrap_messages()
    |> Enum.map(&decode_message_summary/1)
  end

  defp gui_agent_chat_section!(
         <<target_id::8, len::16, payload::binary-size(len), _rest::binary>>,
         target_id
       ),
       do: payload

  defp gui_agent_chat_section!(
         <<_id::8, len::16, _payload::binary-size(len), rest::binary>>,
         target_id
       ),
       do: gui_agent_chat_section!(rest, target_id)

  defp unwrap_messages(<<0xFF::8, 1::8, count::16, frames::binary>>),
    do: unwrap_message_frames(frames, count, [])

  defp unwrap_message_frames(<<>>, 0, acc), do: Enum.reverse(acc)

  defp unwrap_message_frames(
         <<message_len::32, message::binary-size(message_len), rest::binary>>,
         remaining,
         acc
       ),
       do: unwrap_message_frames(rest, remaining - 1, [message | acc])

  defp decode_message_summary(<<id::32, 0x02::8, len::32, text::binary-size(len)>>),
    do: {id, :assistant, text}

  defp decode_message_summary(<<id::32, 0x05::8, _level::8, len::32, text::binary-size(len)>>),
    do: {id, :system, text}
end

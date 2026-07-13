defmodule MingaEditor.Input.AgentNavTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Scroll
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Input.AgentNav
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  @ctrl MingaEditor.Frontend.Protocol.mod_ctrl()

  defp make_state(opts) do
    {:ok, prompt_buf} = BufferProcess.start_link(content: "")
    {:ok, file_buf} = BufferProcess.start_link(content: "file content")

    scroll =
      Scroll.new(Keyword.get(opts, :offset, 5))
      |> Scroll.update_metrics(40, 10)

    agent_ui = %UIState{
      panel: %UIState.Panel{
        visible: true,
        input_focused: Keyword.get(opts, :input_focused, false),
        scroll: scroll,
        prompt_buffer: prompt_buf
      },
      view: %UIState.View{
        active: true,
        focus: Keyword.get(opts, :focus, :chat)
      }
    }

    window = Window.new_agent_chat(1, 24, 80)

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        agent_ui: agent_ui,
        buffers: %Buffers{active: file_buf, list: [file_buf]},
        keymap_scope: :agent,
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %MingaEditor.Shell.Traditional.State{agent: %AgentState{}}
        )
    }
  end

  describe "chat focus navigation" do
    test "j scrolls the semantic transcript down" do
      state = make_state(offset: 5)

      {:handled, new_state} = AgentNav.handle_key(state, ?j, 0)

      assert AgentAccess.panel(new_state).scroll.offset == 6
      refute AgentAccess.panel(new_state).scroll.pinned
    end

    test "k scrolls the semantic transcript up" do
      state = make_state(offset: 5)

      {:handled, new_state} = AgentNav.handle_key(state, ?k, 0)

      assert AgentAccess.panel(new_state).scroll.offset == 4
      refute AgentAccess.panel(new_state).scroll.pinned
    end

    test "Ctrl-D and Ctrl-U page the semantic transcript" do
      {:handled, down_state} = AgentNav.handle_key(make_state(offset: 5), ?d, @ctrl)
      assert AgentAccess.panel(down_state).scroll.offset == 15

      {:handled, up_state} = AgentNav.handle_key(make_state(offset: 15), ?u, @ctrl)
      assert AgentAccess.panel(up_state).scroll.offset == 5
    end

    test "G pins the semantic transcript to the bottom" do
      state = make_state(offset: 5)

      {:handled, new_state} = AgentNav.handle_key(state, ?G, 0)

      assert AgentAccess.panel(new_state).scroll.pinned
    end

    test "unpins the agent chat window when user navigates" do
      state = make_state(offset: 5)

      {:handled, new_state} = AgentNav.handle_key(state, ?j, 0)

      assert Map.fetch!(new_state.workspace.windows.map, 1).pinned == false
    end
  end

  describe "file viewer navigation" do
    test "routes j/k to file viewer scroll state" do
      state = make_state(focus: :file_viewer)

      {:handled, down_state} = AgentNav.handle_key(state, ?j, 0)
      assert down_state.workspace.agent_ui.view.preview.scroll.offset == 1

      {:handled, up_state} = AgentNav.handle_key(down_state, ?k, 0)
      assert up_state.workspace.agent_ui.view.preview.scroll.offset == 0
    end
  end
end

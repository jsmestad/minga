defmodule MingaEditor.State.TabTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaEditor.State.Workspace.RemoteSession
  alias MingaAgent.Subagent.Handle
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.State.Tab.Agent
  alias MingaEditor.State.Tab.File
  alias MingaEditor.VimState

  describe "constructors" do
    test "create typed file and agent tabs" do
      file = Tab.new_file(1)
      agent = Tab.new_agent(2, "Fix the bug")

      assert {file.id, file.kind, file.label, file.payload} == {1, :file, "", %File{}}
      assert Context.empty?(file.context)

      assert {agent.id, agent.kind, agent.label, agent.payload} ==
               {2, :agent, "Fix the bug", %Agent{}}
    end
  end

  describe "set_label/2" do
    test "updates the label" do
      tab = Tab.new_file(1, "old") |> Tab.set_label("new")
      assert tab.label == "new"
    end
  end

  describe "set_context/2" do
    test "stores a context snapshot as a typed struct" do
      editing = VimState.new()
      ctx = %{editing: editing, keymap_scope: :editor}
      tab = Tab.new_file(1) |> Tab.set_context(ctx)
      assert %Context{} = tab.context
      assert tab.context.editing == editing
      assert tab.context.keymap_scope == :editor
    end

    test "migrates legacy vim field into editing" do
      legacy_vim = VimState.new()
      tab = Tab.new_file(1) |> Tab.set_context(%{vim: legacy_vim})
      assert tab.context.editing == legacy_vim
    end

    test "honors encoded present fields during migration" do
      tab = Tab.new_file(1) |> Tab.set_context(%{"present_fields" => [], "editing" => nil})
      assert Context.empty?(tab.context)
    end

    test "drops malformed legacy fields instead of marking them present" do
      tab = Tab.new_file(1) |> Tab.set_context(%{editing: :insert})
      assert Context.empty?(tab.context)
    end

    test "drops invalid keymap scopes" do
      tab = Tab.new_file(1) |> Tab.set_context(%{keymap_scope: :unknown_scope})
      assert Context.empty?(tab.context)
    end

    test "ignores malformed present_fields on externally built structs" do
      context = %Context{present_fields: [:missing_field, "keymap_scope"], keymap_scope: :editor}
      assert Context.to_workspace_map(context) == %{keymap_scope: :editor}
    end

    test "drops malformed values from externally built structs" do
      context = %Context{present_fields: [:keymap_scope], keymap_scope: :unknown_scope}
      assert Context.empty?(context)
      assert Context.to_workspace_map(context) == %{}
    end
  end

  describe "file?/1 and agent?/1" do
    test "identify only the matching payload variant" do
      assert Tab.file?(Tab.new_file(1))
      refute Tab.agent?(Tab.new_file(1))
      assert Tab.agent?(Tab.new_agent(2))
      refute Tab.file?(Tab.new_agent(2))
    end
  end

  describe "variant-only transitions" do
    test "change only their owner variant" do
      {:ok, file_ref} = FileRef.from_path("/tmp/minga", "lib/user.ex")
      remote = RemoteSession.new("srv", "session-1", :connected)
      handle = Handle.new(session_id: "sub-1", pid: self(), task: "work")

      cases = [
        {:agent, &Tab.set_session(&1, self()),
         &match?(%Agent{session: pid} when pid == self(), &1.payload)},
        {:agent, &Tab.refresh_session_pid(&1, self(), self()), &match?(%Agent{}, &1.payload)},
        {:agent, &Tab.set_remote_session(&1, "srv", "session-1", self()),
         &match?(
           %Agent{server_name: "srv", remote_session_id: "session-1", session: pid}
           when pid == self(),
           &1.payload
         )},
        {:agent, &Tab.set_remote_projection(&1, remote),
         &match?(%Agent{server_name: "srv", remote_session_id: "session-1"}, &1.payload)},
        {:agent, &Tab.clear_remote_projection(Tab.set_remote_projection(&1, remote)),
         &match?(%Agent{server_name: nil, remote_session_id: nil}, &1.payload)},
        {:agent,
         &Tab.clear_agent_projection(
           &1
           |> Tab.set_session(self())
           |> Tab.set_agent_status(:thinking)
           |> Tab.set_attention(true)
         ), &match?(%Agent{session: nil, agent_status: nil, attention: false}, &1.payload)},
        {:agent, &Tab.set_connection_status(&1, :disconnected),
         &match?(%Agent{connection_status: :disconnected}, &1.payload)},
        {:agent, &Tab.set_agent_status(&1, :thinking),
         &match?(%Agent{agent_status: :thinking}, &1.payload)},
        {:agent, &Tab.set_attention(&1, true), &match?(%Agent{attention: true}, &1.payload)},
        {:agent, &Tab.mark_background_subagent(&1, handle),
         &match?(%Agent{background_subagent: ^handle}, &1.payload)},
        {:file, &Tab.set_file_ref(&1, file_ref), &match?(%File{file_ref: ^file_ref}, &1.payload)}
      ]

      for {owner, transition, changed?} <- cases do
        file = Tab.new_file(1)
        agent = Tab.new_agent(2)
        assert changed?.(transition.(if owner == :file, do: file, else: agent))

        assert transition.(if owner == :file, do: agent, else: file) ==
                 if(owner == :file, do: agent, else: file)
      end
    end
  end

  describe "scrub_buffer/2" do
    test "removes dead pid from context.buffers" do
      bs = %Buffers{list: [:dead, :live], active: :dead, active_index: 0}
      tab = Tab.new_file(1) |> Tab.set_context(%{buffers: bs})

      result = Tab.scrub_buffer(tab, :dead)

      assert result.context.buffers.list == [:live]
      assert result.context.buffers.active == :live
    end

    test "no-op when context is empty" do
      tab = Tab.new_file(1)
      result = Tab.scrub_buffer(tab, :some_pid)

      assert result == tab
    end

    test "no-op when context has no buffers key" do
      tab = Tab.new_file(1) |> Tab.set_context(%{editing: VimState.new()})
      result = Tab.scrub_buffer(tab, :some_pid)

      assert result == tab
    end
  end
end

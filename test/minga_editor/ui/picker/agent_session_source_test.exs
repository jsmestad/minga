defmodule MingaEditor.UI.Picker.AgentSessionSourceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.RemoteAPI.SessionInfo
  alias MingaAgent.SessionListing
  alias MingaAgent.SessionMetadata
  alias MingaAgent.SessionStore
  alias MingaAgent.Session.Continuation
  alias MingaAgent.TurnUsage
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.UI.Picker.AgentSessionSource

  test "renders unavailable remote metadata without invented session details" do
    info =
      "session-7"
      |> SessionListing.unavailable(self(), :timeout)
      |> SessionInfo.from_listing("token")

    item = AgentSessionSource.remote_session_item("build-host", info)

    assert item.label == "[build-host] session-7"
    assert item.description == "Metadata unavailable (timed out)"
    assert item.annotation == "unavailable"
    assert item.search_text == "session-7"
    refute item.description =~ "unknown"
  end

  test "preserves healthy remote session presentation" do
    now = ~U[2026-09-14 17:30:00Z]

    metadata = %SessionMetadata{
      id: "session-8",
      title: "Fix parser",
      model_name: "gpt-real",
      provider_name: "openai",
      created_at: now,
      last_message_at: now,
      message_count: 4,
      status: :thinking
    }

    info = SessionInfo.new("session-8", self(), "token", metadata)
    item = AgentSessionSource.remote_session_item("build-host", info)

    assert item.label == "[build-host] Fix parser"
    assert item.description == "openai/gpt-real · 4 msgs · Sep 14 17:30"
    assert item.annotation == "thinking"
  end

  @tag :tmp_dir
  test "metadata from an older attached daemon keeps its live row in recents", %{tmp_dir: dir} do
    metadata =
      Map.delete(
        %SessionMetadata{
          id: "legacy-remote",
          title: "Remote task",
          model_name: "test-model",
          created_at: ~U[2026-11-01 00:00:00Z],
          last_message_at: ~U[2026-11-01 00:00:00Z]
        },
        :archived?
      )

    session =
      start_supervised!(
        {Task,
         fn ->
           for _request <- 1..2 do
             receive do
               {:"$gen_call", from, :metadata} -> GenServer.reply(from, metadata)
             end
           end
         end}
      )

    tabs =
      Tab.new_agent(7)
      |> Tab.project_agent_lifecycle(Workspace.new_agent(1, "Remote task", session, nil))
      |> TabBar.new()

    context = %{
      picker_context(dir, false)
      | tab_bar: tabs,
        picker_ui: %{context: %{session_store_dir: dir}}
    }

    save_session("legacy-remote", "Saved copy", dir)

    copies =
      Enum.filter(AgentSessionSource.candidates(context), fn
        %Item{id: {"legacy-remote", _}} -> true
        _ -> false
      end)

    assert [%Item{id: {"legacy-remote", {:tab, 7, ^session}}, annotation: nil} = live] = copies
    assert live.label == "\u{2022} Remote task"

    archived = %{context | picker_ui: %{context: %{session_store_dir: dir, archive_view: true}}}

    refute Enum.any?(AgentSessionSource.candidates(archived), fn item ->
             item.id == {"legacy-remote", {:tab, 7, session}}
           end)
  end

  @tag :tmp_dir
  test "archived saved conversations are findable without appearing in recent sessions", %{
    tmp_dir: dir
  } do
    save_session("archived-target", "Archived task", dir)
    save_session("recent-target", "Recent task", dir)
    assert :ok = SessionStore.set_archived("archived-target", true, dir, [])

    recent = AgentSessionSource.candidates(picker_context(dir, false))
    assert [%Item{label: "Recent task"}, %Item{label: "Browse archived sessions"}] = recent

    archived = AgentSessionSource.candidates(picker_context(dir, true))

    assert [
             %Item{label: "Back to recent sessions"},
             %Item{id: {"archived-target", {:disk, nil}}, label: "[Archived] Archived task"}
           ] = archived

    assert :ok = SessionStore.set_archived("archived-target", false, dir, [])

    assert Enum.sort(
             Enum.map(AgentSessionSource.candidates(picker_context(dir, false)), & &1.label)
           ) ==
             ["Archived task", "Recent task"]
  end

  defp save_session(id, title, dir) do
    assert :ok =
             SessionStore.save(
               %{
                 id: id,
                 timestamp: "2026-11-01T00:00:00Z",
                 model_name: "test-model",
                 messages: [{:user, title}],
                 usage: TurnUsage.new(),
                 continuation: Continuation.new()
               },
               dir
             )
  end

  defp picker_context(dir, archive_view?) do
    %Context{
      buffers: %Buffers{},
      editing: VimState.new(),
      search: %Search{},
      viewport: Viewport.new(24, 80),
      tab_bar: TabBar.new(Tab.new_file(1, "fixture.txt")),
      picker_ui: %{
        context: %{persisted_only: true, session_store_dir: dir, archive_view: archive_view?}
      },
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end
end

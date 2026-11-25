defmodule MingaEditor.Agent.SessionWorkingFolderTest do
  @moduledoc """
  Where the Editor tells a new Agent session to work when no project is detected (#4266).

  The test process plays the Editor, as in `MingaEditor.Agent.SessionStartTest`. Its files live outside the checkout, because every folder inside it belongs to a detected project.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.AgentSessionStart
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  @no_folder "Minga has no folder to work in. Open a file or a folder."

  setup do
    outside =
      Path.join(System.tmp_dir!(), "minga-working-folder-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(outside, "lib"))
    on_exit(fn -> File.rm_rf!(outside) end)
    {:ok, canonical} = Minga.Project.Root.canonical_path(outside)
    %{outside: canonical}
  end

  test "a file outside any project: the session works in the file's folder, not the process directory",
       %{outside: outside} do
    file = Path.join(outside, "lib/other.ex")
    File.write!(file, "defmodule Other do\nend\n")
    manager = recording_manager()

    _opened = manager |> state() |> with_file(file) |> AgentCommands.new_agent_session()

    assert_receive {:start_requested, ^manager, opts}
    provider_opts = Keyword.fetch!(opts, :provider_opts)
    folder = Path.join(outside, "lib")

    assert Keyword.fetch!(provider_opts, :working_folder) == {:folder, folder}
    assert Keyword.fetch!(provider_opts, :project_root) == folder

    assert %MingaAgent.ProjectView{project_root: ^folder} =
             Keyword.fetch!(provider_opts, :project_view)

    refute folder == File.cwd!()
  end

  test "with several files open, the session works beside the file the person is in, not the first one opened",
       %{outside: outside} do
    first = Path.join(outside, "first/a.txt")
    current = Path.join(outside, "second/b.txt")
    for file <- [first, current], do: File.mkdir_p!(Path.dirname(file))
    for file <- [first, current], do: File.write!(file, "")
    manager = recording_manager()

    _opened =
      manager
      |> state()
      |> with_files([first, current], current)
      |> AgentCommands.new_agent_session()

    assert_receive {:start_requested, ^manager, opts}

    assert opts |> Keyword.fetch!(:provider_opts) |> Keyword.fetch!(:working_folder) ==
             {:folder, Path.join(outside, "second")}
  end

  test "the conversation says once which folder Minga works in", %{outside: outside} do
    file = Path.join(outside, "lib/other.ex")
    File.write!(file, "")
    session = spawn_link(fn -> receive(do: (:never -> :ok)) end)
    manager = spawn_link(fn -> reply_once({:ok, "session-1", session}) end)

    opened = manager |> state() |> with_file(file) |> AgentCommands.new_agent_session()
    :erlang.trace(session, true, [:receive])
    bound = AgentSessionStart.settle(opened)

    line =
      "Minga is working in #{Minga.Project.collapse_home(Path.join(outside, "lib"))}. No project was detected there."

    assert_receive {:trace, ^session, :receive,
                    {:"$gen_cast", {:add_system_message, ^line, :info}}}

    refute match?({:failed, _failure}, bound.workspace.agent_ui.chat_lifecycle)
  end

  test "no file and no folder: the session starts without a folder, says so once, and nothing has failed" do
    session = spawn_link(fn -> receive(do: (:never -> :ok)) end)
    test = self()

    manager =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, {:start_session, opts}} ->
            send(test, {:start_requested, self(), opts})
            GenServer.reply(from, {:ok, "session-1", session})
        end
      end)

    opened = manager |> state() |> AgentCommands.new_agent_session()
    :erlang.trace(session, true, [:receive])
    bound = AgentSessionStart.settle(opened)

    assert_receive {:start_requested, ^manager, opts}
    provider_opts = Keyword.fetch!(opts, :provider_opts)
    assert Keyword.fetch!(provider_opts, :working_folder) == {:unavailable, :none}
    refute Keyword.has_key?(provider_opts, :project_root)
    assert Keyword.fetch!(provider_opts, :project_view) == nil

    assert_receive {:trace, ^session, :receive,
                    {:"$gen_cast", {:add_system_message, @no_folder, :info}}}

    refute match?({:failed, _failure}, bound.workspace.agent_ui.chat_lifecycle)
  end

  test "a file directly in the home directory gives no folder and names why" do
    home = Path.expand("~")
    manager = recording_manager()

    # The buffer names the path; nothing is written into the home directory.
    _opened =
      manager
      |> state()
      |> with_file(Path.join(home, "minga-4266-notes.txt"))
      |> AgentCommands.new_agent_session()

    assert_receive {:start_requested, ^manager, opts}
    {:ok, canonical_home} = Minga.Project.Root.canonical_path(home)

    assert opts |> Keyword.fetch!(:provider_opts) |> Keyword.fetch!(:working_folder) ==
             {:unavailable, {:too_broad, canonical_home}}
  end

  test "a restored conversation that can only be read offers a new conversation by key and by click" do
    line =
      "This conversation can only be read here. Start a new conversation, or restore it in /work/notes."

    state =
      recording_manager()
      |> state()
      |> MingaEditor.Agent.Events.dispatch(self(), {:conversation_read_only, line})

    assert [notification] =
             Enum.filter(
               state.feedback.notifications.items,
               &(&1.id == "agent:conversation_read_only")
             )

    key =
      Minga.Keymap.Scope.Agent.new_session_key_hint(
        Minga.Keymap.leader_trie(),
        state.interaction.editing_model,
        Minga.Config.get(:space_leader)
      )

    assert is_binary(key)
    assert notification.title == "This conversation can only be read"
    assert notification.body == "Key: #{key} starts a new conversation. #{line}"

    assert [%{id: "new_conversation", label: "New conversation", dispatch: action}] =
             notification.actions

    # The click runs the command the key runs.
    assert action == {:command, :agent_new_session}

    assert {:ok, _command} =
             Minga.Command.Registry.lookup(Minga.Command.Registry, :agent_new_session)
  end

  test "the read-only card goes away when the conversation on screen is one that continues" do
    read_only_card? = fn state ->
      Enum.any?(state.feedback.notifications.items, &(&1.id == "agent:conversation_read_only"))
    end

    shown =
      recording_manager()
      |> state()
      |> MingaEditor.Agent.Events.dispatch(self(), {:conversation_read_only, "This one is read."})

    assert read_only_card?.(shown)

    continued = MingaEditor.Agent.Events.dispatch(shown, self(), :conversation_continues)
    refute read_only_card?.(continued)
  end

  defp state(manager) do
    state = TestHelpers.base_state(rendering: :disabled)

    state =
      MingaEditor.WorkspaceWorkflow.install_tab_bar(state, TabBar.new(Tab.new_file(1, "f.ex")))

    connection = AgentConnection.new(Minga.Test.StubProvider)
    %{state | agent_connection: %{connection | session_manager: manager}}
  end

  # Makes `path` the file the person is in.
  defp with_file(state, path), do: with_files(state, [path], path)

  # Opens `paths` in order and makes `current` the file the person is in.
  defp with_files(state, paths, current) do
    opened =
      for path <- paths,
          do: {path, start_supervised!({BufferProcess, file_path: path}, id: {:buffer, path})}

    list = Enum.map(opened, &elem(&1, 1))
    {_path, active} = List.keyfind(opened, current, 0)

    buffers = %Buffers{
      active: active,
      list: list,
      active_index: Enum.find_index(list, &(&1 == active))
    }

    %{state | workspace: SessionState.set_buffers(state.workspace, buffers)}
  end

  defp recording_manager do
    test = self()

    spawn_link(fn ->
      receive do
        {:"$gen_call", _from, {:start_session, opts}} ->
          send(test, {:start_requested, self(), opts})
          receive(do: (:never -> :ok))
      end
    end)
  end

  defp reply_once(reply) do
    receive do
      {:"$gen_call", from, {:start_session, _opts}} -> GenServer.reply(from, reply)
    end
  end
end

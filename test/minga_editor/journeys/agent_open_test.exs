defmodule MingaEditor.Journeys.AgentOpenTest do
  @moduledoc """
  Exercises real key dispatch through the committed semantic Agent chat frame.

  The test provider and shared warm model catalog do not exercise the first-open freeze in #3610. The shipping-app journey in #3644 owns that check.

  These journeys assert the first frame a timely Agent tab arrival commits. The production arrival budget (250 ms) is wall-clock time that a loaded CI runner can spend before the destination Session answers; the Editor then correctly commits an Unavailable frame first. `MingaEditor.Agent.ConcurrentSessionsTest` covers that timeout path. The Editors here use a generous budget so "timely" does not depend on runner load.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias Minga.Distribution.Events.NodeDisconnectedEvent
  alias Minga.Project.FileRef
  alias Minga.Test.HeadlessPort
  alias Minga.Test.StubServer
  alias MingaAgent.Session
  alias MingaAgent.Subagent.Handle
  alias MingaAgent.ToolApproval.{Preview, Public, Target}
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Persistence
  alias MingaEditor.State.WorkspaceReview

  @moduletag :tmp_dir
  @capabilities %Capabilities{frontend_type: :native_gui, semantic_ui: true}

  @arrival_budget_ms 4_000

  setup %{tmp_dir: dir}, do: %{editor_ctx: open_editor(dir)}

  defp open_editor(dir) do
    path = Path.join(dir, "journey.txt")
    contents = "A file open before Agent starts"
    File.write!(path, contents)
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    start_editor(contents,
      file_path: path,
      project_root: dir,
      shell: :traditional,
      capabilities: @capabilities,
      options_server: options,
      agent_provider_module: Minga.Test.StubProvider,
      agent_arrival_budget_ms: @arrival_budget_ms
    )
  end

  test "SPC a a opens an empty composer focused in Insert from an editor with only a file", %{
    editor_ctx: ctx
  } do
    refute match?(%{visible?: true}, agent_chat(ctx))

    assert %{
             visible?: true,
             lifecycle: :starting,
             prompt: "",
             prompt_vim_mode: 1,
             input_focused?: true
           } = frame_after_open(ctx, "<SPC>a", "a")

    assert %{visible?: true, lifecycle: :conversation, prompt: "", prompt_vim_mode: 1} =
             await_conversation(ctx, prompt: "")
  end

  test "SPC a n opens a focused Insert composer", %{editor_ctx: ctx} do
    assert %{
             visible?: true,
             lifecycle: :starting,
             prompt: "",
             prompt_vim_mode: 1,
             input_focused?: true
           } = frame_after_open(ctx, "<SPC>a", "n")

    assert %{
             visible?: true,
             lifecycle: :conversation,
             prompt: "",
             prompt_vim_mode: 1,
             input_focused?: true
           } = await_conversation(ctx, prompt: "")
  end

  test "the frame for the final open key shows the starting composer before the session exists",
       %{editor_ctx: ctx} do
    assert %{visible?: true, lifecycle: :starting, prompt: "", input_focused?: true} =
             frame_after_open(ctx, "<SPC>a", "n")

    assert %{visible?: true, lifecycle: :conversation} = await_conversation(ctx)
  end

  test "keys typed before the open edit the file and keys after it fill the starting draft",
       %{editor_ctx: ctx} do
    send_keys_async(ctx, "x<SPC>anearly draft")

    assert %{visible?: true, prompt: "early draft"} =
             await_conversation(ctx, prompt: "early draft")

    send_keys_async(ctx, "<Esc><SPC>aa")

    assert Minga.Buffer.content(editor_state(ctx).workspace.buffers.active) ==
             " file open before Agent starts"
  end

  test "Ctrl+C and Escape both leave Replace mode in the composer", %{editor_ctx: ctx} do
    send_keys_async(ctx, "<SPC>anxyz<Esc>0Rab")
    assert %{prompt: "abz", prompt_vim_mode: 6, input_focused?: true} = agent_chat(ctx)

    send_keys_async(ctx, "<C-c>")
    assert %{prompt: "abz", prompt_vim_mode: 0, input_focused?: true} = agent_chat(ctx)

    send_keys_async(ctx, "Rc<Esc>")
    assert %{prompt: "abc", prompt_vim_mode: 0, input_focused?: true} = agent_chat(ctx)
  end

  test "keys immediately following SPC a n appear in the new composer", %{editor_ctx: ctx} do
    send_keys_async(ctx, "<SPC>anmy draft")

    assert %{visible?: true, prompt: "my draft"} = agent_chat(ctx)
  end

  test "toggling to the file and back keeps the same draft", %{editor_ctx: ctx} do
    send_keys_async(ctx, "<SPC>aaunfinished<Esc>")
    assert %{visible?: true, prompt: "unfinished"} = agent_chat(ctx)

    send_keys_async(ctx, "<SPC>aa")
    refute match?(%{visible?: true}, agent_chat(ctx))

    send_keys_async(ctx, "<SPC>aa")
    assert %{visible?: true, prompt: "unfinished"} = await_conversation(ctx, prompt: "unfinished")
  end

  # SPC TAB a retired with tabs (docs/design/keys.md); the command stays reachable by name.
  test "the next agent tab command from the file reopens the existing draft", %{editor_ctx: ctx} do
    send_keys_async(ctx, "<SPC>anexisting<Esc>")
    assert %{visible?: true, prompt: "existing"} = agent_chat(ctx)

    send_keys_async(ctx, "<SPC>aa")
    refute match?(%{visible?: true}, agent_chat(ctx))

    send_gui_action(ctx, {:execute_command, "cycle_agent_tabs"})
    assert %{visible?: true, prompt: "existing"} = await_conversation(ctx, prompt: "existing")
  end

  test "tab clicks, workspace navigation and Sessions restore the intended Agent draft", %{
    editor_ctx: ctx
  } do
    manual = Runtime.active_tab(editor_state(ctx).shell_runtime)
    send_keys_async(ctx, "<SPC>anarrival draft<Esc>")
    assert %{prompt: "arrival draft"} = await_conversation(ctx, prompt: "arrival draft")
    agent = Runtime.active_tab(editor_state(ctx).shell_runtime)
    assert agent.id != manual.id

    send_gui_action(ctx, {:select_tab, manual.id})
    await_hidden_conversation(ctx)

    frame = HeadlessPort.prepare_await(ctx.port)
    send(ctx.editor, {:minga_input, {:gui_action, {:select_tab, agent.id}}})

    assert {:ok,
            %{agent_chat: %{visible?: true, lifecycle: :conversation, prompt: "arrival draft"}}} =
             HeadlessPort.collect_frame(frame)

    send_keys_async(ctx, "<SPC>ansecond draft<Esc>")

    assert %{visible?: true, lifecycle: :conversation, prompt: "second draft"} =
             await_conversation(ctx, prompt: "second draft")

    send_gui_action(ctx, {:execute_command, "workspace_prev"})

    assert %{visible?: true, lifecycle: :conversation, prompt: "arrival draft"} =
             await_conversation(ctx, prompt: "arrival draft")

    send_gui_action(ctx, {:execute_command, "workspace_next"})

    assert %{visible?: true, lifecycle: :conversation, prompt: "second draft"} =
             await_conversation(ctx, prompt: "second draft")

    send_gui_action(ctx, {:execute_command, "agent_session_switcher"})
    offer = modal_picker!(ctx).picker_ui.activation_offer
    tab_id = agent.id
    session = agent.payload.session

    {id, _, _} =
      Enum.find(offer.items, fn {_id, _index, item} ->
        match?({_record, {:tab, ^tab_id, ^session}}, item.id)
      end)

    send_gui_action(ctx, %MingaEditor.Target{
      surface: :picker,
      intent: :activate_item,
      generation: offer.generation,
      item_id: <<id::32>>
    })

    refute picker_open?(ctx)

    assert %{visible?: true, lifecycle: :conversation, prompt: "arrival draft"} =
             await_conversation(ctx, prompt: "arrival draft")
  end

  test "an Agent tab click waits out a Session slower than the default budget and commits its conversation first",
       %{editor_ctx: ctx} do
    manual = Runtime.active_tab(editor_state(ctx).shell_runtime)
    send_keys_async(ctx, "<SPC>anlate draft<Esc>")
    assert %{prompt: "late draft"} = await_conversation(ctx, prompt: "late draft")
    agent = Runtime.active_tab(editor_state(ctx).shell_runtime)

    send_gui_action(ctx, {:select_tab, manual.id})
    refute match?(%{visible?: true}, agent_chat(ctx))

    # The suspended Session stands in for a loaded runner. The production budget
    # would commit an Unavailable frame inside this window.
    :ok = :sys.suspend(agent.payload.session)
    frame = HeadlessPort.prepare_await(ctx.port)
    send(ctx.editor, {:minga_input, {:gui_action, {:select_tab, agent.id}}})

    assert {:error, :timeout} =
             HeadlessPort.collect_frame(frame, 2 * AgentConnection.default_arrival_budget_ms())

    :ok = :sys.resume(agent.payload.session)

    assert {:ok, %{agent_chat: %{visible?: true, lifecycle: :conversation, prompt: "late draft"}}} =
             HeadlessPort.collect_frame(frame)
  end

  test "closing a file tab restores the previous Agent composer", %{
    editor_ctx: ctx
  } do
    send_keys_async(ctx, "<SPC>anwork in progress<Esc>")
    agent = Runtime.active_tab(editor_state(ctx).shell_runtime)
    send_gui_action(ctx, :new_tab)
    scratch = Runtime.active_tab(editor_state(ctx).shell_runtime)
    assert scratch.id != agent.id
    assert scratch.group_id == agent.group_id
    refute match?(%{visible?: true}, agent_chat(ctx))

    send_gui_action(ctx, {:close_tab, scratch.id})

    assert %{visible?: true, lifecycle: :conversation, prompt: "work in progress"} =
             await_conversation(ctx, prompt: "work in progress")
  end

  test "closing an inactive file restores an editable Agent composer after its buffer died", %{
    editor_ctx: ctx
  } do
    file = active_tab(ctx)
    send_keys_async(ctx, "<SPC>an")
    composer = editor_state(ctx).workspace.agent_ui.panel.prompt_buffer
    :ok = GenServer.stop(composer)

    send_gui_action(ctx, {:close_tab, file.id})

    assert %{visible?: true, lifecycle: :conversation, prompt: "", prompt_vim_mode: 1} =
             await_conversation(ctx, prompt: "")

    send_keys_async(ctx, "Recovered composer<Esc>")
    assert %{visible?: true, prompt: "Recovered composer"} = agent_chat(ctx)
  end

  test "closing the only file arrives in a completed background sub-agent", %{editor_ctx: ctx} do
    file = active_tab(ctx)
    announce_background_session(ctx)

    send_gui_action(ctx, {:close_tab, file.id})

    assert %{visible?: true, lifecycle: :conversation, prompt: ""} =
             await_conversation(ctx, prompt: "")

    send_keys_async(ctx, "iChild draft<Esc>")
    assert %{visible?: true, prompt: "Child draft"} = agent_chat(ctx)
  end

  test "selecting a background sub-agent opens its editable conversation", %{editor_ctx: ctx} do
    handle = announce_background_session(ctx)
    tabs = editor_state(ctx).shell_runtime.state.tab_bar
    child = TabBar.find_by_session(tabs, handle.pid)
    refute match?(%{visible?: true}, agent_chat(ctx))

    send_gui_action(ctx, {:select_tab, child.id})

    assert %{visible?: true, lifecycle: :conversation, prompt: ""} =
             await_conversation(ctx, prompt: "")
  end

  test "an authenticated remote arrival does not revive from queued events after disconnect", %{
    editor_ctx: ctx,
    tmp_dir: dir
  } do
    assert {:ok, %{session_id: record, pid: session, token: token}} =
             MingaAgent.RemoteAPI.start_session(
               provider: Minga.Test.StubProvider,
               session_store_dir: dir
             )

    on_exit(fn -> MingaAgent.SessionManager.stop_session(record) end)

    connect =
      {:connect_remote_session,
       %{server_name: "Journey host", session_id: record, pid: session, token: token}}

    assert :ok = GenServer.call(ctx.editor, {:api_execute_command, connect})
    send_keys_async(ctx, "iRemote draft<Esc>")
    assert %{visible?: true, lifecycle: :conversation, prompt: "Remote draft"} = agent_chat(ctx)

    target = Target.new(record, "request-1", "approval-1")
    approval = Public.new(target, "shell", %{}, Preview.new(:command, "Check", ["pwd"]))
    send(ctx.editor, {:agent_event, session, {:approval_pending, approval}})
    agent = Traditional.State.agent(editor_state(ctx).shell_runtime.state)
    refute is_nil(agent.pending_approval)

    disconnect = %NodeDisconnectedEvent{
      server_name: "Journey host",
      node: node(),
      reason: :connection_lost,
      disconnected_at: DateTime.utc_now()
    }

    %{connection: connection} = Session.editor_snapshot(session)
    send(ctx.editor, {:minga_event, :node_disconnected, disconnect})
    send(ctx.editor, {:agent_event, session, {:connection_changed, connection}})
    send(ctx.editor, {:agent_event, session, {:approval_pending, approval}})
    send_keys_async(ctx, "A stays<Esc>")

    assert %{visible?: true, lifecycle: :unavailable, prompt: "Remote draft stays"} =
             agent_chat(ctx)

    assert is_nil(Traditional.State.agent(editor_state(ctx).shell_runtime.state).pending_approval)
  end

  test "promoting an answered Inline Ask opens its Agent composer", %{editor_ctx: ctx} do
    send_gui_action(ctx, {:execute_command, "inline_ask"})

    :sys.replace_state(ctx.editor, fn state ->
      ask =
        Traditional.State.inline_asks(state.shell_runtime.state)
        |> Map.fetch!(ctx.buffer)
        |> InlineAsk.append_input("What is this file?")
        |> InlineAsk.thinking(self())
        |> InlineAsk.append_response("A journey fixture.")
        |> InlineAsk.answered()

      Traditional.Workflow.install_inline_ask(state, ask)
    end)

    send_keys_async(ctx, "\t")

    assert %{visible?: true, lifecycle: :conversation, prompt: ""} =
             await_conversation(ctx, prompt: "")

    send_keys_async(ctx, "iFollow-up draft<Esc>")
    assert %{visible?: true, prompt: "Follow-up draft"} = agent_chat(ctx)
  end

  test "revealing a persisted pending Review opens its unavailable Agent composer", %{
    tmp_dir: dir
  } do
    root = Path.join(dir, "pending-review")
    File.mkdir_p!(root)
    {:ok, file} = FileRef.from_path(root, "journey.txt")

    assert :ok =
             Workspace.new_agent(41, "Journey review", nil, root)
             |> Workspace.set_review(%WorkspaceReview{
               state: :needs_review,
               changed_files: [file]
             })
             |> Persistence.write(root)

    ctx = open_editor(root)
    send_gui_action(ctx, {:execute_command, "workspace_pending_reviews"})
    offer = modal_picker!(ctx).picker_ui.activation_offer
    assert [{id, _, %{id: 41}}] = offer.items

    send_gui_action(ctx, %MingaEditor.Target{
      surface: :picker,
      intent: :activate_item,
      generation: offer.generation,
      item_id: <<id::32>>
    })

    refute picker_open?(ctx)
    assert %{visible?: true, lifecycle: :unavailable, prompt: ""} = agent_chat(ctx)
  end

  defp active_tab(ctx), do: Runtime.active_tab(editor_state(ctx).shell_runtime)

  # Returns the first frame committed for `final_key`, after `prefix` has been handled.
  defp frame_after_open(ctx, prefix, final_key) do
    send_keys_async(ctx, prefix)
    frame = HeadlessPort.prepare_await(ctx.port)
    send_keys_async(ctx, final_key)
    assert {:ok, %{agent_chat: chat}} = HeadlessPort.collect_frame(frame)
    chat
  end

  # Waits for a committed frame showing a live conversation with `expected`
  # fields. A tab or workspace switch holds the previous committed frame until
  # the destination Session's ordered arrival capture crosses Ingest
  # (`MingaEditor.Agent.Arrival`), so the latest frame right after the switch
  # can still be the departed conversation; matching the expected draft waits
  # for the destination's own frame.
  defp await_conversation(ctx, expected \\ []),
    do: await_conversation(ctx, expected, System.monotonic_time(:millisecond) + 5_000)

  defp await_conversation(ctx, expected, deadline) do
    ref = HeadlessPort.prepare_await(ctx.port)
    model = agent_chat(ctx)

    if conversation?(model, expected) do
      model
    else
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      case HeadlessPort.collect_frame(ref, timeout) do
        {:ok, _snapshot} ->
          await_conversation(ctx, expected, deadline)

        {:error, :timeout} ->
          flunk(
            "No committed Agent conversation matching #{inspect(expected)}; last model: #{inspect(model)}"
          )
      end
    end
  end

  # `send_gui_action/2` returns after the first frame committed once the action is
  # sent, which can be a render scheduled before the editor handled it (the new
  # conversation's draft and arrival work renders on its own). Wait for the frame
  # that shows the conversation gone.
  defp await_hidden_conversation(ctx),
    do: await_hidden_conversation(ctx, System.monotonic_time(:millisecond) + 5_000)

  defp await_hidden_conversation(ctx, deadline) do
    ref = HeadlessPort.prepare_await(ctx.port)
    model = agent_chat(ctx)

    if match?(%{visible?: true}, model) do
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      case HeadlessPort.collect_frame(ref, timeout) do
        {:ok, _snapshot} -> await_hidden_conversation(ctx, deadline)
        {:error, :timeout} -> flunk("The Agent conversation stayed visible: #{inspect(model)}")
      end
    else
      model
    end
  end

  defp conversation?(%{lifecycle: :conversation} = model, expected),
    do: Enum.all?(expected, fn {key, value} -> Map.get(model, key) == value end)

  defp conversation?(_model, _expected), do: false

  defp announce_background_session(ctx) do
    child =
      start_supervised!(
        {StubServer, messages: [{:user, "Inspect the file"}, {:assistant, "Child completed"}]}
      )

    handle = Handle.new(session_id: "journey-child", pid: child, task: "Inspect the file")
    send(ctx.editor, {:minga_event, :background_subagent_started, handle})
    _ = editor_state(ctx)
    handle
  end

  test "a restored workspace without a live session shows Unavailable and accepts a draft", %{
    tmp_dir: dir
  } do
    restored_dir = Path.join(dir, "restored")
    File.mkdir_p!(restored_dir)

    assert :ok =
             Workspace.new_agent(41, "Saved journey", nil, restored_dir)
             |> Persistence.write(restored_dir)

    ctx = open_editor(restored_dir)
    send_gui_action(ctx, {:execute_command, "workspace_next"})

    assert %{visible?: true, lifecycle: :unavailable, prompt: ""} = agent_chat(ctx)

    send_keys_async(ctx, "iunfinished draft<Esc>")

    assert %{visible?: true, lifecycle: :unavailable, prompt: "unfinished draft"} =
             agent_chat(ctx)
  end
end

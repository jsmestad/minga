defmodule MingaEditor.NativeIPC.NavigationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias MingaEditor.NativeIPC.Identity
  alias MingaEditor.NativeIPC.NativePresentationObservation
  alias MingaEditor.NativeIPC.Navigation
  alias MingaEditor.NativeIPC.NavigationCommand
  alias MingaEditor.NativeIPC.Server
  alias MingaEditor.PickerUI
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Frontend, as: FrontendState
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers
  import ExUnit.CaptureLog

  defmodule ChoiceSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "Semantic choices"

    @impl true
    def candidates(_context) do
      Enum.map(1..60, fn id -> %Item{id: id, label: "Choice #{id}"} end)
    end

    @impl true
    def on_select(_item, state), do: state
  end

  defmodule LargeChoiceSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: String.duplicate("T", 1_000)

    @impl true
    def candidates(_context) do
      Enum.map(1..100, fn id ->
        %Item{
          id: id,
          label: String.duplicate("L", 1_000),
          description: String.duplicate("D", 1_000),
          annotation: String.duplicate("A", 1_000)
        }
      end)
    end

    @impl true
    def on_select(_item, state), do: state
  end

  defmodule InterleavingBuffer do
    use GenServer

    @spec start_link(pid()) :: GenServer.on_start()
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner) do
      Process.put(:"$initial_call", {Minga.Buffer.Process, :init, 1})
      {:ok, %{version: 1, cursor: {0, 0}, owner: owner}}
    end

    @impl true
    def handle_call(:version, _from, state), do: {:reply, state.version, state}

    def handle_call(:cursor, _from, state), do: {:reply, state.cursor, state}

    def handle_call(:filetype, _from, state) do
      send(state.owner, :precommit_highlight_effect)
      {:reply, :text, state}
    end

    def handle_call(
          {:resolve_utf16_position_if_version, version, 1, 0},
          _from,
          %{version: version} = state
        ) do
      send(self(), :interleaving_edit)
      {:reply, {:ok, {0, 0}}, state}
    end

    def handle_call(
          {:move_to_utf16_if_version, version, _line, _column},
          _from,
          %{version: actual} = state
        )
        when version != actual,
        do: {:reply, {:error, :stale}, state}

    @impl true
    def handle_info(:interleaving_edit, state),
      do: {:noreply, %{state | version: state.version + 1}}
  end

  defmodule PostCommitFailingBuffer do
    use GenServer

    @spec start_link(pid()) :: GenServer.on_start()
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner) do
      Process.put(:"$initial_call", {Minga.Buffer.Process, :init, 1})
      {:ok, %{version: 1, cursor: {0, 0}, owner: owner}}
    end

    @impl true
    def handle_call(:version, _from, state), do: {:reply, state.version, state}
    def handle_call(:cursor, _from, state), do: {:reply, state.cursor, state}

    def handle_call({:resolve_utf16_position_if_version, 1, 1, 1}, _from, state),
      do: {:reply, {:ok, {0, 1}}, state}

    def handle_call({:move_to_utf16_if_version, 1, 1, 1}, _from, state) do
      send(state.owner, :post_commit_cursor_moved)
      {:reply, {:ok, {0, 1}}, %{state | cursor: {0, 1}}}
    end

    def handle_call(:filetype, _from, state) do
      send(state.owner, :post_commit_highlight_attempted)
      {:stop, :filetype_failed, state}
    end
  end

  setup do
    identity =
      Identity.new(
        app_instance_id: "app-instance-navigation",
        core_instance_id: "core-instance-navigation",
        app_pid: 123,
        euid: 501,
        launch_nonce: nil,
        socket_path: "/tmp/navigation.sock",
        token: "secret"
      )

    state = base_state(content: "zero\na😀b\nlast") |> install_tab_bar()
    %{identity: identity, state: state}
  end

  test "inspection returns exact opaque targets, one-based UTF-16 positions, and bounded viewport",
       %{
         identity: identity,
         state: state
       } do
    assert {:ok, inspection} = Navigation.inspect(state, identity, nil, 25)
    assert inspection["app_instance_id"] == identity.app_instance_id
    assert inspection["core_instance_id"] == identity.core_instance_id
    assert inspection["authoritative"]["active_tab_id"] == 1

    [tab] = inspection["authoritative"]["tabs"]
    [pane] = tab["panes"]
    assert tab["target_token"] =~ ~r/^\d+$/
    assert pane["target_token"] =~ ~r/^\d+$/
    assert pane["buffer"]["cursor"] == %{"line" => 1, "column" => 0}
    assert pane["viewport"]["start_line"] == 1
    assert Enum.count(pane["viewport"]["lines"]) <= 8
    assert inspection["presented"]["status"] == "committed_not_native_observed"
  end

  test "goto-location accepts an exact Unicode boundary and rejects a stale revision without redirecting",
       %{
         identity: identity,
         state: state
       } do
    {:ok, inspection} = Navigation.inspect(state, identity, nil, 25)
    [tab] = inspection["authoritative"]["tabs"]
    [pane] = tab["panes"]
    buffer = state.workspace.buffers.active

    command =
      command!(%{
        "type" => "goto_location",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "tab_id" => tab["id"],
        "pane_id" => pane["id"],
        "target_token" => pane["target_token"],
        "buffer_id" => pane["buffer"]["id"],
        "buffer_revision" => pane["buffer"]["revision"],
        "line" => 2,
        "column" => 3
      })

    assert {:ok, moved, :editor_visible_focused} = Navigation.apply(state, identity, command)
    assert Buffer.cursor(buffer) == {1, 5}
    assert moved.workspace.windows.active == 1

    :ok = Buffer.insert_text(buffer, "!")
    cursor = Buffer.cursor(buffer)
    assert {:error, :stale_revision} = Navigation.apply(state, identity, command)
    assert Buffer.cursor(buffer) == cursor
  end

  test "goto-location rejects a UTF-16 surrogate midpoint", %{identity: identity, state: state} do
    {:ok, inspection} = Navigation.inspect(state, identity, nil, 25)
    [tab] = inspection["authoritative"]["tabs"]
    [pane] = tab["panes"]

    command =
      command!(%{
        "type" => "goto_location",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "tab_id" => tab["id"],
        "pane_id" => pane["id"],
        "target_token" => pane["target_token"],
        "buffer_id" => pane["buffer"]["id"],
        "buffer_revision" => pane["buffer"]["revision"],
        "line" => 2,
        "column" => 2
      })

    assert {:error, :column_not_boundary} = Navigation.apply(state, identity, command)
    assert Buffer.cursor(state.workspace.buffers.active) == {0, 0}
  end

  test "goto-location preserves the requested position while focusing a different pane", %{
    identity: identity,
    state: state
  } do
    buffer = state.workspace.buffers.active

    windows =
      Windows.new(nil, 1, 3, %{
        1 => Window.new(1, buffer, 24, 80, {0, 0}),
        2 => Window.new(2, buffer, 24, 80, {2, 0})
      })

    workspace = SessionState.set_windows(state.workspace, windows)
    state = %{state | workspace: workspace} |> install_tab_bar()
    assert {:ok, inspection} = Navigation.inspect(state, identity, nil, 25)
    [tab] = inspection["authoritative"]["tabs"]
    pane = Enum.find(tab["panes"], &(&1["id"] == 2))

    command =
      command!(%{
        "type" => "goto_location",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "tab_id" => tab["id"],
        "pane_id" => pane["id"],
        "target_token" => pane["target_token"],
        "buffer_id" => pane["buffer"]["id"],
        "buffer_revision" => pane["buffer"]["revision"],
        "line" => 2,
        "column" => 3
      })

    assert {:ok, moved, :editor_visible_focused} = Navigation.apply(state, identity, command)
    assert moved.workspace.windows.active == 2
    assert Buffer.cursor(buffer) == {1, 5}
  end

  test "goto-location leaves cursor and focus unchanged when an edit interleaves before commit",
       %{
         identity: identity,
         state: state
       } do
    buffer = start_supervised!({InterleavingBuffer, self()})
    target_buffers = state.workspace.buffers |> Buffers.add(buffer)

    target_windows =
      Windows.new(nil, 1, 3, %{
        1 => Window.new(1, buffer, 24, 80, {0, 0}),
        2 => Window.new(2, buffer, 24, 80, {0, 0})
      })

    target_workspace =
      state.workspace
      |> SessionState.set_buffers(target_buffers)
      |> SessionState.set_windows(target_windows)

    {tab_bar, target_tab} = TabBar.insert(current_tab_bar(state), :file, "target.ex")

    tab_bar =
      TabBar.update_context(tab_bar, target_tab.id, Context.snapshot(target_workspace))

    state = install_tab_bar(state, tab_bar)
    buffer_id = Navigation.token(identity, :buffer, [inspect(buffer)])

    command =
      command!(%{
        "type" => "goto_location",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "tab_id" => target_tab.id,
        "pane_id" => 2,
        "target_token" =>
          Navigation.token(identity, :pane, [target_tab.id, 2, {:buffer, buffer_id}])
          |> Integer.to_string(),
        "buffer_id" => Integer.to_string(buffer_id),
        "buffer_revision" => 1,
        "line" => 1,
        "column" => 0
      })

    assert {:error, :stale_revision} = Navigation.apply(state, identity, command)
    assert GenServer.call(buffer, :cursor) == {0, 0}
    assert state.workspace.windows.active == 1
    assert current_tab_bar(state).active_id == 1
    refute_receive :precommit_highlight_effect
  end

  test "goto-location remains applied when post-commit highlighting exits", %{
    identity: identity,
    state: state
  } do
    buffer = start_supervised!({PostCommitFailingBuffer, self()})
    target_buffers = state.workspace.buffers |> Buffers.add(buffer)

    target_windows =
      Windows.new(nil, 1, 2, %{1 => Window.new(1, buffer, 24, 80, {0, 0})})

    target_workspace =
      state.workspace
      |> SessionState.set_buffers(target_buffers)
      |> SessionState.set_windows(target_windows)

    {tab_bar, target_tab} = TabBar.insert(current_tab_bar(state), :file, "target.ex")
    tab_bar = TabBar.update_context(tab_bar, target_tab.id, Context.snapshot(target_workspace))
    state = install_tab_bar(state, tab_bar)
    buffer_id = Navigation.token(identity, :buffer, [inspect(buffer)])

    command =
      command!(%{
        "type" => "goto_location",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "tab_id" => target_tab.id,
        "pane_id" => 1,
        "target_token" =>
          Navigation.token(identity, :pane, [target_tab.id, 1, {:buffer, buffer_id}])
          |> Integer.to_string(),
        "buffer_id" => Integer.to_string(buffer_id),
        "buffer_revision" => 1,
        "line" => 1,
        "column" => 1
      })

    log =
      capture_log(fn ->
        assert {:ok, moved, :editor_visible_focused} =
                 Navigation.apply(state, identity, command)

        assert current_tab_bar(moved).active_id == target_tab.id
        assert moved.workspace.windows.active == 1
      end)

    assert_received :post_commit_cursor_moved
    assert_received :post_commit_highlight_attempted
    assert log =~ "Semantic navigation applied, but tab_highlight finalization failed"
  end

  test "selected unnamed-buffer tab records applied pane before unavailable" do
    {receipt_server, identity} = start_receipt_server()
    state = base_state(content: "unnamed", rendering: :disabled) |> install_tab_bar()
    buffer = state.workspace.buffers.active

    target_windows =
      Windows.new(nil, 7, 8, %{7 => Window.new(7, buffer, 24, 80, {0, 0})})

    target_workspace = SessionState.set_windows(state.workspace, target_windows)
    {tab_bar, target_tab} = TabBar.insert(current_tab_bar(state), :file, "unnamed")
    tab_bar = TabBar.update_context(tab_bar, target_tab.id, Context.snapshot(target_workspace))
    state = install_tab_bar(state, tab_bar)

    command =
      command!(%{
        "type" => "select_tab",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "tab_id" => target_tab.id,
        "target_token" => Navigation.token(identity, :tab, [target_tab.id]) |> Integer.to_string()
      })

    assert {:ok, receipt} =
             Server.admit_navigation_operation(
               receipt_server,
               :select_tab,
               NavigationCommand.receipt_target(command),
               :editor_visible_focused
             )

    assert receipt.target.window_id == 0

    assert {:reply, :ok, applied_state} =
             MingaEditor.handle_call(
               {:native_navigation, identity, command, receipt, receipt_server},
               {self(), make_ref()},
               state
             )

    assert current_tab_bar(applied_state).active_id == target_tab.id
    assert applied_state.workspace.windows.active == 7

    assert {:ok, terminal} =
             Server.lookup_operation(
               receipt_server,
               identity.app_instance_id,
               identity.core_instance_id,
               receipt.operation_id
             )

    assert terminal.phase == :terminal
    assert terminal.outcome == :unavailable
    assert is_integer(terminal.applied_at_ms)
    assert terminal.applied_at_ms <= terminal.terminal_at_ms
    assert terminal.application_revision == 1
    assert terminal.target.window_id == 7
    assert terminal.target.token == command.target_token
    assert terminal.target.kind == :select_tab
    assert terminal.detail == "target has no native editor presentation"
  end

  test "inspection uses the live cursor only for the active pane", %{
    identity: identity,
    state: state
  } do
    buffer = state.workspace.buffers.active
    :ok = Buffer.move_to(buffer, {1, 5})

    windows =
      Windows.new(nil, 1, 3, %{
        1 => Window.new(1, buffer, 24, 80, {0, 2}),
        2 => Window.new(2, buffer, 24, 80, {2, 2})
      })

    state =
      %{state | workspace: SessionState.set_windows(state.workspace, windows)}
      |> install_tab_bar()

    assert {:ok, inspection} = Navigation.inspect(state, identity, nil, 25)
    [tab] = inspection["authoritative"]["tabs"]
    active = Enum.find(tab["panes"], &(&1["id"] == 1))
    inactive = Enum.find(tab["panes"], &(&1["id"] == 2))

    assert active["buffer"]["cursor"] == %{"line" => 2, "column" => 3}
    assert inactive["buffer"]["cursor"] == %{"line" => 3, "column" => 2}

    continuation_state =
      %{state | workspace: SessionState.set_windows(state.workspace, many_windows(buffer))}

    assert {:ok, first} = Navigation.inspect(continuation_state, identity, nil, 25)
    continuation = first["continuations"]["panes"]["1"]

    changed_windows =
      Windows.replace_window(
        continuation_state.workspace.windows,
        2,
        Window.set_cursor(Map.fetch!(continuation_state.workspace.windows.map, 2), {1, 0})
      )

    changed = %{
      continuation_state
      | workspace: SessionState.set_windows(continuation_state.workspace, changed_windows)
    }

    assert {:error, :stale_continuation} = Navigation.inspect(changed, identity, continuation, 25)
  end

  test "native presentation changes invalidate inspection continuations", %{
    identity: identity,
    state: state
  } do
    buffer = state.workspace.buffers.active
    state = %{state | workspace: SessionState.set_windows(state.workspace, many_windows(buffer))}
    assert {:ok, first} = Navigation.inspect(state, identity, nil, 25)
    continuation = first["continuations"]["panes"]["1"]

    observation = %NativePresentationObservation{
      target_token: 9,
      application_revision: 2,
      generation: 1,
      frame_seq: 3,
      window_id: 1,
      focus_ready: true
    }

    changed = %{
      state
      | frontend: FrontendState.observe_native_presentation(state.frontend, observation)
    }

    assert {:error, :stale_continuation} = Navigation.inspect(changed, identity, continuation, 25)
  end

  test "picker inspection paginates by revision and activation uses the existing semantic route",
       %{
         identity: identity,
         state: state
       } do
    opened = PickerUI.open(state, ChoiceSource)
    assert {:ok, first} = Navigation.inspect(opened, identity, nil, 10)
    picker = first["authoritative"]["picker"]
    assert Enum.count(picker["choices"]) == 10
    assert picker["truncated"]
    assert is_binary(picker["continuation"])

    assert {:ok, second} = Navigation.inspect(opened, identity, picker["continuation"], 10)
    assert second["authoritative"]["picker"]["choice_offset"] == 10

    [choice | _rest] = picker["choices"]

    command =
      command!(%{
        "type" => "activate_picker_choice",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "target_token" => picker["target_token"],
        "picker_generation" => picker["generation"],
        "activation_id" => choice["activation_id"],
        "choice_kind" => "item"
      })

    assert {:ok, activated, :beam_applied} = Navigation.apply(opened, identity, command)
    assert activated.shell_runtime.state.modal == :none

    replaced = PickerUI.open(opened, ChoiceSource)

    assert {:error, :stale_continuation} =
             Navigation.inspect(replaced, identity, picker["continuation"], 10)

    assert {:error, :picker_replaced} = Navigation.apply(replaced, identity, command)
  end

  test "removed pane and old core identities reject without changing active focus", %{
    identity: identity,
    state: state
  } do
    {:ok, inspection} = Navigation.inspect(state, identity, nil, 25)
    [tab] = inspection["authoritative"]["tabs"]
    [pane] = tab["panes"]

    focus =
      command!(%{
        "type" => "focus_pane",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "tab_id" => tab["id"],
        "pane_id" => pane["id"] + 10,
        "target_token" => pane["target_token"]
      })

    assert {:error, :pane_not_found} = Navigation.apply(state, identity, focus)
    assert state.workspace.windows.active == 1

    old_core = %{focus | pane_id: pane["id"], core_instance_id: "old-core"}
    assert {:error, :core_replaced} = Navigation.apply(state, identity, old_core)
    assert state.workspace.windows.active == 1
  end

  test "inspection paginates every tab with a revision-scoped continuation", %{
    identity: identity,
    state: state
  } do
    tab_bar = current_tab_bar(state)

    tab_bar =
      Enum.reduce(2..10, tab_bar, fn id, tabs ->
        {tabs, _tab} = TabBar.insert(tabs, :file, "tab-#{id}.ex")
        tabs
      end)

    state = install_tab_bar(state, tab_bar)
    expected_ids = Enum.map(tab_bar.tabs, & &1.id)
    assert {:ok, first} = Navigation.inspect(state, identity, nil, 25)
    assert Enum.map(first["authoritative"]["tabs"], & &1["id"]) == Enum.take(expected_ids, 8)
    assert first["truncation"]["tabs"]
    continuation = first["continuations"]["tabs"]
    assert is_binary(continuation)

    assert {:ok, second} = Navigation.inspect(state, identity, continuation, 25)
    assert Enum.map(second["authoritative"]["tabs"], & &1["id"]) == Enum.drop(expected_ids, 8)
    refute second["truncation"]["tabs"]
    assert second["continuations"]["tabs"] == nil

    changed = PickerUI.open(state, ChoiceSource)
    assert {:error, :stale_continuation} = Navigation.inspect(changed, identity, continuation, 25)
  end

  test "inspection paginates every pane without serializing whole buffers", %{
    identity: identity,
    state: state
  } do
    buffer = state.workspace.buffers.active

    windows =
      1..10
      |> Map.new(fn id -> {id, Window.new(id, buffer, 24, 80)} end)
      |> then(&Windows.new(nil, 1, 11, &1))

    workspace = SessionState.set_windows(state.workspace, windows)
    state = %{state | workspace: workspace}

    assert {:ok, first} = Navigation.inspect(state, identity, nil, 25)
    [first_tab] = first["authoritative"]["tabs"]
    assert Enum.map(first_tab["panes"], & &1["id"]) == Enum.to_list(1..8)
    assert first_tab["panes_truncated"]
    continuation = first["continuations"]["panes"]["1"]
    assert continuation == first_tab["pane_continuation"]

    assert {:ok, second} = Navigation.inspect(state, identity, continuation, 25)
    [second_tab] = second["authoritative"]["tabs"]
    assert second_tab["id"] == 1
    assert Enum.map(second_tab["panes"], & &1["id"]) == [9, 10]
    refute second_tab["panes_truncated"]
    assert second["continuations"]["panes"]["1"] == nil
  end

  test "maximum bounded pane and picker projection stays within one IPC frame", %{
    identity: identity,
    state: state
  } do
    content = Enum.map_join(1..8, "\n", fn _line -> String.duplicate("x", 1_000) end)
    :ok = Buffer.replace_content(state.workspace.buffers.active, content)
    buffer = state.workspace.buffers.active

    windows =
      1..8
      |> Map.new(fn id -> {id, Window.new(id, buffer, 24, 80)} end)
      |> then(&Windows.new(nil, 1, 9, &1))

    workspace = SessionState.set_windows(state.workspace, windows)

    state =
      %{state | workspace: workspace} |> install_tab_bar() |> PickerUI.open(LargeChoiceSource)

    assert {:ok, inspection} = Navigation.inspect(state, identity, nil, 25)
    assert byte_size(JSON.encode!(inspection)) <= 65_536
    assert inspection["truncation"]["picker_choices"]
  end

  defp install_tab_bar(state) do
    tab = Tab.new_file(1, "one.ex")
    tab_bar = TabBar.new(tab) |> TabBar.update_context(1, Context.snapshot(state.workspace))
    install_tab_bar(state, tab_bar)
  end

  defp install_tab_bar(state, tab_bar) do
    shell_state = TraditionalState.install_tab_bar(Runtime.state(state.shell_runtime), tab_bar)
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end

  defp current_tab_bar(state),
    do: state.shell_runtime |> Runtime.state() |> TraditionalState.tab_bar()

  defp many_windows(buffer) do
    1..10
    |> Map.new(fn id -> {id, Window.new(id, buffer, 24, 80, {0, 0})} end)
    |> then(&Windows.new(nil, 1, 11, &1))
  end

  defp start_receipt_server do
    suffix = System.unique_integer([:positive])
    runtime_parent = Path.join("/tmp", "minga-nav-receipt-#{suffix}")
    runtime_dir = Path.join(runtime_parent, "com.minga.editor")
    task_supervisor = Module.concat(__MODULE__, "ReceiptTasks#{suffix}")
    File.mkdir!(runtime_parent)
    File.chmod!(runtime_parent, 0o700)
    start_supervised!({Task.Supervisor, name: task_supervisor})

    receipt_server =
      start_supervised!(
        {Server,
         name: nil,
         task_supervisor: task_supervisor,
         runtime_parent: runtime_parent,
         runtime_dir: runtime_dir,
         app_instance_id: "app-instance-receipt-#{suffix}",
         app_pid: System.pid() |> String.to_integer(),
         euid: File.stat!(File.cwd!()).uid,
         launch_nonce: "launch-nonce-receipt-#{suffix}"}
      )

    on_exit(fn -> File.rm_rf!(runtime_parent) end)
    {receipt_server, Server.identity(receipt_server)}
  end

  defp command!(map) do
    {:ok, command} = NavigationCommand.parse(map)
    command
  end
end

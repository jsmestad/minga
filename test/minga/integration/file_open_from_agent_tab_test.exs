defmodule Minga.Integration.FileOpenFromAgentTabTest do
  @moduledoc """
  Integration test for opening a file while the agent tab is active.

  Reproduces a bug where `SPC f f` (file picker) selects a file and
  the tab bar correctly shows the new file tab, but the content area
  renders blank. The tab is there, the buffer exists, but nothing draws.

  Root cause: `sync_active_window_buffer/1` updates `window.buffer` but
  not `window.content`. The render pipeline checks `Content.agent_chat?`
  to skip agent windows from the normal buffer rendering path, so the
  window keeps being treated as agent chat. But `add_buffer_as_new_tab`
  already reset the agentic view state, so the agent chat renderer draws
  nothing. Result: blank content area.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Test.HeadlessPort
  alias Minga.Test.StubServer

  @moduletag :tmp_dir

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Starts an editor in agent mode: agent tab active, agent chat window,
  # keymap scope set to :agent. This mirrors the state when Minga boots
  # into the agentic view (the default).
  @spec start_editor_in_agent_mode(keyword()) :: map()
  defp start_editor_in_agent_mode(opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    id = :erlang.unique_integer([:positive])

    {:ok, port} = HeadlessPort.start_link(width: width, height: height)

    # Create the agent buffer (the *Agent* chat buffer)
    agent_buf = AgentBufferSync.start_buffer()
    assert is_pid(agent_buf), "Failed to start agent buffer"

    # Create a file buffer so the editor has something in the buffer list
    {:ok, file_buf} = BufferServer.start_link(content: "", buffer_name: "unnamed")

    # Start the editor with the file buffer; we'll reconfigure the
    # state to look like agent mode below.
    {:ok, editor} =
      Editor.start_link(
        name: :"headless_agent_editor_#{id}",
        port_manager: port,
        buffer: file_buf,
        width: width,
        height: height
      )

    # Reconfigure the editor state to agent mode. This replicates what
    # Startup.build_initial_state does when keymap_scope is :agent.
    {:ok, fake_session} = StubServer.start_link()

    :sys.replace_state(editor, fn state ->
      win_id = state.workspace.windows.active

      agent_window = Window.new_agent_chat(win_id, agent_buf, height, width)

      windows = %{
        state.workspace.windows
        | map: Map.put(state.workspace.windows.map, win_id, agent_window)
      }

      agent_tab_bar = TabBar.new(Tab.new_agent(1, "Agent"))

      agent_state =
        state.shell_state.agent
        |> Map.put(:buffer, agent_buf)
        |> Map.put(:session, fake_session)

      ss = state.shell_state

      %{
        state
        | workspace: %{state.workspace | windows: windows, keymap_scope: :agent},
          shell_state: %{ss | tab_bar: agent_tab_bar, agent: agent_state},
          # Suppress :tool_missing events from the global event bus.
          # Without this, a stray tool_missing broadcast can race with
          # open_file and transition to :tool_confirm mode, causing the
          # modeline test to see "INSTALL" instead of "NORMAL".
          suppress_tool_prompts: true
      }
    end)

    # Trigger a render so the agent view is visible
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    {:ok, _snapshot} = HeadlessPort.collect_frame(ref)

    %{
      editor: editor,
      buffer: file_buf,
      agent_buffer: agent_buf,
      port: port,
      width: width,
      height: height
    }
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "opening a file from the agent tab" do
    test "window content type switches from agent_chat to buffer", %{tmp_dir: tmp_dir} do
      # This test pinpoints the root cause: after add_buffer from an
      # agent tab, window.content must be {:buffer, file_pid}, not
      # {:agent_chat, old_pid}. If content stays agent_chat, the render
      # pipeline treats the window as an agent chat window and skips
      # normal buffer rendering.
      ctx = start_editor_in_agent_mode()

      # Confirm we start in agent mode with agent_chat window
      state = :sys.get_state(ctx.editor)
      win_id = state.workspace.windows.active
      window = Map.get(state.workspace.windows.map, win_id)
      assert Content.agent_chat?(window.content), "Should start with agent_chat window"

      # Create a test file and open it
      file_path = Path.join(tmp_dir, "content_type_test.exs")
      File.write!(file_path, "defmodule ContentTypeTest do\n  :ok\nend\n")

      ref = HeadlessPort.prepare_await(ctx.port)
      :ok = Editor.open_file(ctx.editor, file_path)
      {:ok, _snapshot} = HeadlessPort.collect_frame(ref)

      # After opening a file, the window content MUST be {:buffer, _}
      state = :sys.get_state(ctx.editor)
      win_id = state.workspace.windows.active
      window = Map.get(state.workspace.windows.map, win_id)

      assert Content.buffer?(window.content),
             "Window content should be {:buffer, _} after opening file, " <>
               "got #{inspect(window.content)}"
    end

    test "file content is visible on screen after opening", %{tmp_dir: tmp_dir} do
      ctx = start_editor_in_agent_mode()

      file_path = Path.join(tmp_dir, ".credo.exs")

      File.write!(file_path, """
      %{
        configs: [
          %{
            name: "default",
            files: %{
              included: ["lib/", "test/"],
              excluded: []
            }
          }
        ]
      }
      """)

      ref = HeadlessPort.prepare_await(ctx.port)
      :ok = Editor.open_file(ctx.editor, file_path)
      {:ok, _snapshot} = HeadlessPort.collect_frame(ref)

      # Tab bar should show the file
      tab_row = screen_row(ctx, 0)

      assert String.contains?(tab_row, ".credo.exs"),
             "Tab bar should show .credo.exs, got: #{inspect(tab_row)}"

      # Content rows (rows 1 through height-2, excluding tab bar and modeline)
      # must contain the file's text, not be blank.
      content_rows =
        1..(ctx.height - 2)
        |> Enum.map(&screen_row(ctx, &1))
        |> Enum.filter(&(String.trim(&1) != ""))

      assert content_rows != [],
             "Content area should have non-empty rows. Screen:\n#{Enum.join(screen_text(ctx), "\n")}"

      assert Enum.any?(content_rows, &String.contains?(&1, "configs")),
             "File content 'configs' should appear in content rows. Content rows:\n" <>
               Enum.join(content_rows, "\n")
    end

    test "modeline shows file info, not agent prompt", %{tmp_dir: tmp_dir} do
      ctx = start_editor_in_agent_mode()

      file_path = Path.join(tmp_dir, "modeline_test.txt")
      File.write!(file_path, "hello\nworld")

      ref = HeadlessPort.prepare_await(ctx.port)
      :ok = Editor.open_file(ctx.editor, file_path)
      {:ok, _snapshot} = HeadlessPort.collect_frame(ref)

      ml = modeline(ctx)

      # Modeline should show normal file-editing indicators
      assert String.contains?(ml, "NORMAL"),
             "Modeline should show NORMAL mode, got: #{inspect(ml)}"

      # Modeline should NOT show agent prompt indicators
      refute String.contains?(ml, "Prompt"),
             "Modeline should not show 'Prompt' after opening file, got: #{inspect(ml)}"
    end

    test "keymap scope switches to :editor", %{tmp_dir: tmp_dir} do
      ctx = start_editor_in_agent_mode()

      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :agent

      file_path = Path.join(tmp_dir, "scope_test.txt")
      File.write!(file_path, "test content")

      ref = HeadlessPort.prepare_await(ctx.port)
      :ok = Editor.open_file(ctx.editor, file_path)
      {:ok, _snapshot} = HeadlessPort.collect_frame(ref)

      state = :sys.get_state(ctx.editor)

      assert state.workspace.keymap_scope == :editor,
             "Scope should be :editor after opening file, got #{state.workspace.keymap_scope}"
    end

    # Tests 5-6 ("normal mode editing works", "tab switch back to agent")
    # were removed. They tested motion/insert and tab switching, not the
    # file-open-from-agent-tab bug fix. The motion test was flaky because
    # Events.broadcast(:buffer_opened) triggers async messages from
    # Git.Tracker/LSP/FileWatcher that race with subsequent keystrokes.
    # The tab switch test had a silent-pass bug (conditional assertion on
    # hardcoded mouse coordinates). Motion and insert are already covered
    # by the motion and mode test suites. Tab switching belongs in a
    # dedicated tab lifecycle test with proper mouse hit-testing.
  end
end

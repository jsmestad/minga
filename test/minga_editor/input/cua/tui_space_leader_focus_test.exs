defmodule MingaEditor.Input.CUA.TUISpaceLeaderFocusTest do
  @moduledoc """
  SPC in CUA mode on the terminal frontend reaches the focused surface and never edits a file buffer hidden behind it (#3956 AC3).

  `CUA.TUISpaceLeader` types the space at once and retracts it when a leader key follows. Only the focused file buffer takes that space. Agent chat navigation and a focused bottom panel take no text: SPC followed by a leader key still starts the leader there, and the file behind them never changes. The cursor sits at the end of the file, so a retraction from the wrong buffer would delete a real character.
  """

  # The terminal backend never acknowledges a headless frame, so these editors
  # run without rendering and change focus inside the Editor process.
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Config.Options
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.BottomPanel
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow

  @moduletag :tmp_dir

  describe "the focused file buffer" do
    test "a lone SPC types a space into the file", %{tmp_dir: dir} do
      ctx = cua_tui_editor(dir)

      send_keys_sync(ctx, "<SPC>")

      assert buffer_content(ctx) == "focus "
      refute Minga.Editing.in_leader?(editor_state(ctx))
    end

    test "SPC f f retracts the space and opens find-file", %{tmp_dir: dir} do
      ctx = cua_tui_editor(dir)

      send_keys_sync(ctx, "<SPC>ff")

      assert picker_open?(ctx)
      assert buffer_content(ctx) == "focus"
    end
  end

  for {surface, focus} <- [
        agent_chat: &__MODULE__.focus_agent_chat/1,
        bottom_panel: &__MODULE__.focus_bottom_panel/1
      ] do
    describe "a focused #{surface}" do
      @focus focus

      test "a lone SPC leaves the hidden file unchanged", %{tmp_dir: dir} do
        ctx = cua_tui_editor(dir)
        :sys.replace_state(ctx.editor, @focus)

        send_keys_sync(ctx, "<SPC>")

        assert buffer_content(ctx) == "focus"
        refute Minga.Editing.in_leader?(editor_state(ctx))
      end

      test "SPC f f opens find-file without editing the hidden file", %{tmp_dir: dir} do
        ctx = cua_tui_editor(dir)
        :sys.replace_state(ctx.editor, @focus)

        send_keys_sync(ctx, "<SPC>ff")

        assert picker_open?(ctx)
        assert buffer_content(ctx) == "focus"
      end
    end
  end

  for {composer, panel_visible?} <- [side_panel_composer: true, agent_tab_composer: false] do
    test "a focused #{composer} takes the space and the hidden file does not", %{tmp_dir: dir} do
      ctx = cua_tui_editor(dir)
      :sys.replace_state(ctx.editor, &focus_composer(&1, unquote(panel_visible?)))

      send_keys_sync(ctx, "<SPC>")

      assert PromptBuffer.prompt_text(editor_state(ctx).workspace.agent_ui) == " "
      assert buffer_content(ctx) == "focus"
    end
  end

  @doc false
  # Agent chat navigation: the Agent scope has keyboard focus and the composer does not.
  @spec focus_agent_chat(MingaEditor.State.t()) :: MingaEditor.State.t()
  def focus_agent_chat(state) do
    refute state.workspace.agent_ui.panel.input_focused
    %{state | workspace: SessionState.set_keymap_scope(state.workspace, :agent)}
  end

  @doc false
  @spec focus_bottom_panel(MingaEditor.State.t()) :: MingaEditor.State.t()
  def focus_bottom_panel(state) do
    shell_state = Runtime.state(state.shell_runtime)
    panel = shell_state.bottom_panel |> BottomPanel.show() |> BottomPanel.focus()
    shell_state = TraditionalState.install_bottom_panel(shell_state, panel)
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end

  # The side panel composer is visible over the editor; an Agent tab's composer
  # has the Agent scope without the side panel.
  defp focus_composer(state, panel_visible?) do
    agent_ui = state.workspace.agent_ui
    agent_ui = if panel_visible?, do: UIState.toggle(agent_ui), else: agent_ui
    agent_ui = PromptBuffer.set_input_focused(agent_ui, true)

    state
    |> focus_agent_chat()
    |> Workflow.install_agent_ui(agent_ui)
  end

  defp cua_tui_editor(dir) do
    path = Path.join(dir, "focus.txt")
    File.write!(path, "focus")
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    ctx =
      start_editor("focus",
        file_path: path,
        project_root: dir,
        editing_model: :cua,
        backend: :tui,
        options_server: options
      )

    Minga.Buffer.move_to(ctx.buffer, {0, 5})
    ctx
  end
end

defmodule MingaEditor.Frontend.Emit.AdapterGUIChromeCacheTest do
  @moduledoc """
  Tests fingerprint-based change detection in the RenderModel adapter path.

  All chrome components use the `RenderModel.UI.Builder` + `Adapter.GUI` path. These tests verify
  that the adapter correctly handles fingerprint caching and change detection.
  """

  # Not async: frame construction reads the process-wide extension panel and semantic UI registries.
  use ExUnit.Case, async: false

  alias Minga.Frontend.Adapter.GUI, as: AdapterGUI
  alias Minga.Frontend.Adapter.GUI.Caches, as: AdapterCaches
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.Builder
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.Test.UnknownGuiPayloadShell

  import ExUnit.CaptureLog
  import MingaEditor.RenderPipeline.TestHelpers

  defmodule PreviewSource do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "Preview source"

    @impl true
    def preview?, do: true

    @impl true
    def live_preview?, do: false

    @impl true
    def gui_preview?, do: true

    @impl true
    def candidates(_ctx), do: [%Item{id: :preview, label: "preview"}]

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state

    @impl true
    def preview(_item, _ctx), do: [[{"source preview", 0xFFFFFF, false}]]
  end

  describe "adapter fingerprint caching" do
    test "first frame sends chrome commands, then fingerprinted components are cached" do
      state = gui_state()

      {_ctx, caches, first_cmds} = encode_via_adapter(state)
      assert first_cmds != []

      # The second call re-emits the status bar (no fingerprint, always sent)
      # but all fingerprinted components should be cached.
      {_ctx, _caches, second_cmds} = encode_via_adapter(state, caches)

      # Only status bar (0x76) should appear; everything else is cached
      non_status_bar = Enum.reject(second_cmds, &opcode?(&1, 0x76))

      assert non_status_bar == [],
             "Only status bar should be re-emitted on unchanged second frame"
    end

    test "theme is emitted through adapter on first call" do
      state = gui_state()
      {_ctx, _caches, cmds} = encode_via_adapter(state)

      assert opcode_count(cmds, 0x74) == 1,
             "theme command should appear in adapter output"
    end

    test "re-sends chrome when state changes between calls" do
      state = gui_state(content: long_content(50))
      {_ctx, caches, _cmds} = encode_via_adapter(state)

      changed_state = EditorState.apply_theme(state, MingaEditor.UI.Theme.get!(:one_dark))
      {_ctx, _caches2, cmds} = encode_via_adapter(changed_state, caches)

      assert opcode_count(cmds, 0x74) == 1,
             "theme command should appear after theme change"
    end

    test "tab bar is emitted through adapter" do
      state =
        then(gui_state(), fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              TabBar.new(Tab.new_file(1, "test.ex"))
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      {_ctx, _caches, cmds} = encode_via_adapter(state)

      assert opcode_count(cmds, 0x71) == 1,
             "tab bar command should appear in adapter output"
    end

    test "unsupported shell GUI payload logs and keeps standard chrome" do
      state = gui_state()
      entry = %{Runtime.entry(state.shell_runtime) | module: UnknownGuiPayloadShell}

      unsupported_state = %{
        state
        | shell_runtime: Runtime.new(entry, Runtime.state(state.shell_runtime))
      }

      {{_ctx, _caches, cmds}, log} =
        with_log(fn -> encode_via_adapter(unsupported_state) end)

      assert log =~ "Unsupported GUI shell payload"
      assert is_list(cmds)
    end

    test "workspaces are emitted through adapter" do
      state = gui_state()
      tab_bar = tab_bar_with_two_workspaces()

      state_with_agents =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              tab_bar
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      {_ctx, _caches, first_cmds} = encode_via_adapter(state_with_agents)

      assert opcode_count(first_cmds, 0x98) == 1,
             "workspace command should appear in adapter output"
    end

    test "agent chat survives dead prompt buffer process" do
      state = gui_state()
      {:ok, dead_pid} = Agent.start(fn -> nil end)
      Agent.stop(dead_pid)

      panel = %{state.workspace.agent_ui.panel | prompt_buffer: dead_pid}

      state = %{
        state
        | workspace: %{state.workspace | agent_ui: %{state.workspace.agent_ui | panel: panel}}
      }

      {ctx, _caches, _cmds} = encode_via_adapter(state)
      assert is_map(ctx)
    end
  end

  defp encode_via_adapter(state, adapter_caches \\ AdapterCaches.new(), status_bar_data \\ nil) do
    ctx = Context.from_editor_state(state)
    sb_data = status_bar_data || StatusBarData.from_state(state)
    {ui_model, ctx} = Builder.build_ui(ctx, sb_data)
    {cmds, adapter_caches} = AdapterGUI.encode_ui(ui_model, adapter_caches)

    {ctx, adapter_caches, cmds}
  end

  defp opcode_count(cmds, opcode), do: cmds |> opcode_cmds(opcode) |> length()
  defp opcode_cmds(cmds, opcode), do: Enum.filter(cmds, &opcode?(&1, opcode))
  defp opcode?(<<opcode, _::binary>>, opcode), do: true
  defp opcode?(_, _opcode), do: false

  defp tab_bar_with_two_workspaces do
    tab_bar = TabBar.new(Tab.new_file(1, "a.ex"))
    {tab_bar, workspace_a} = TabBar.add_workspace(tab_bar, "A")
    {tab_bar, workspace_b} = TabBar.add_workspace(tab_bar, "B")
    {tab_bar, tab_b} = TabBar.insert(tab_bar, :file, "b.ex")

    tab_bar
    |> TabBar.move_tab_to_workspace(1, workspace_a.id)
    |> TabBar.move_tab_to_workspace(tab_b.id, workspace_b.id)
  end
end

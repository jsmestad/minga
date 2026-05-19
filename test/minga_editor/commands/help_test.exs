defmodule MingaEditor.Commands.HelpTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias MingaEditor.Commands.Help
  alias MingaEditor.KeystrokeHistory
  alias MingaEditor.KeystrokeHistory.Entry
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.UI.Picker.CommandHelpSource
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.OptionSource
  alias MingaEditor.Viewport

  defp build_state do
    {:ok, buf} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {BufferProcess, content: "hello", buffer_name: "test.txt"}
      )

    {:ok, keymap} = ActiveKeymap.start_link(name: nil)
    {:ok, options} = Options.start_link(name: nil)

    %EditorState{
      port_manager: nil,
      keymap_server: keymap,
      options_server: options,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]}
      }
    }
  end

  describe "describe-key help" do
    test "describe_key_result opens or reuses read-only *Help* and clears status" do
      state = MingaEditor.State.set_status(build_state(), "Press key to describe:")

      assert {:ok, false} =
               Options.set_for_filetype(state.options_server, :text, :autopair_block, false)

      result = Help.execute(state, {:describe_key_result, "j", :move_down, "Move cursor down"})
      help = result.workspace.buffers.help

      assert is_pid(help)
      assert result.workspace.buffers.active == help
      assert result.shell_state.status_msg == nil
      assert BufferProcess.read_only?(help)
      assert BufferProcess.get_option(help, :autopair_block) == false

      content = BufferProcess.content(help)
      assert content =~ "Key:         j"
      assert content =~ "Command:     move_down"
      assert content =~ "Description: Move cursor down"

      version = BufferProcess.version(help)
      reused = Help.execute(result, {:describe_key_result, "k", :move_up, "Move cursor up"})

      assert reused.workspace.buffers.help == help
      assert BufferProcess.version(help) > version
      assert BufferProcess.content(help) =~ "Command:     move_up"
      refute BufferProcess.content(help) =~ "Command:     move_down"
    end

    test "describe_key_not_found shows the unbound key" do
      result = Help.execute(build_state(), {:describe_key_not_found, "z"})
      assert BufferProcess.content(result.workspace.buffers.help) =~ "Key not bound: z"
    end
  end

  describe "bindings help" do
    test "bindings content includes built-in, text-object, filetype, and user bindings" do
      state = build_state()
      BufferProcess.set_filetype(state.workspace.buffers.active, :elixir)

      ActiveKeymap.bind(
        state.keymap_server,
        :normal,
        "SPC x y",
        :custom_command,
        "Custom command"
      )

      content = Help.bindings_content(state)

      for expected <- [
            "+file",
            "SPC f s",
            "save",
            "Movement",
            "w",
            "word_forward",
            "Text objects",
            "iw",
            "+filetype :elixir",
            "SPC m t t",
            "SPC x y",
            "custom_command",
            "*user*"
          ] do
        assert content =~ expected
      end
    end

    test "describe_bindings opens a read-only *Bindings* buffer" do
      result = Help.execute(build_state(), :describe_bindings)
      buffer = result.workspace.buffers.active

      assert BufferProcess.buffer_name(buffer) == "*Bindings*"
      assert BufferProcess.read_only?(buffer)
      assert BufferProcess.content(buffer) =~ "# Keybindings"
    end
  end

  describe "option help" do
    test "describes default, configured, filetype, buffer-local, and extension options" do
      state = build_state()

      default = Help.describe_option(state, :tab_width) |> help_content()
      assert default =~ "# Option: tab_width"
      assert default =~ "Current value: 2"
      assert default =~ "Default: 2"
      assert default =~ "Type: positive integer"
      assert default =~ "Set by: default"
      assert default =~ "Description:"

      Options.set(state.options_server, :agent_model, "test-model")
      configured = Help.describe_option(state, :agent_model) |> help_content()
      assert configured =~ "Current value: \"test-model\""
      assert configured =~ "Set by: default → config.exs"

      filetype_state = build_state()
      BufferProcess.set_filetype(filetype_state.workspace.buffers.active, :go)
      Options.set_for_filetype(filetype_state.options_server, :go, :agent_model, "go-model")
      filetype = Help.describe_option(filetype_state, :agent_model) |> help_content()
      assert filetype =~ "Current value: \"go-model\""
      assert filetype =~ "Set by: default → filetype :go"

      BufferProcess.set_option(state.workspace.buffers.active, :tab_width, 6)
      local = Help.describe_option(state, :tab_width) |> help_content()
      assert local =~ "Current value: 6"
      assert local =~ "Set by: default → buffer-local"

      Options.register_extension_schema(
        state.options_server,
        :minga_org,
        [{:conceal, :boolean, true, "Hide markup syntax."}],
        conceal: false
      )

      extension = Help.describe_extension_option(state, :minga_org, :conceal) |> help_content()
      assert extension =~ "# Option: minga_org.conceal"
      assert extension =~ "Current value: false"
      assert extension =~ "Set by: default → config.exs"
      assert extension =~ "Hide markup syntax."
    end

    test "option picker uses editor options even when the active buffer is dead" do
      state = build_state()
      Options.set(state.options_server, :agent_model, "test-model")

      item = option_item(state, :agent_model)
      assert item.description =~ "\"test-model\""
      assert item.annotation == "modified"

      buffer = state.workspace.buffers.active
      monitor = Process.monitor(buffer)
      GenServer.stop(buffer)
      assert_receive {:DOWN, ^monitor, :process, ^buffer, _reason}

      assert option_item(state, :agent_model).description =~ "\"test-model\""
    end
  end

  describe "command help" do
    test "reverse keybinding map includes leader, normal, filetype, missing, and multi-bound commands" do
      map = Help.build_reverse_keybind_map()

      assert "SPC f s" in Map.get(map, :save, [])
      assert "j" in Map.get(map, :move_down, [])
      assert "SPC m a" in Map.get(map, :alternate_file, [])
      assert Map.get(map, :nonexistent_command_xyz, []) == []
      assert "SPC s p" in Map.get(map, :search_project, [])
      assert "SPC /" in Map.get(map, :search_project, [])
    end

    test "format_describe_command handles keybindings, no binding, multiple bindings, and scopes" do
      cases = [
        {%Minga.Command{
           name: :save,
           description: "Save the current file",
           execute: fn state -> state end
         }, %{save: ["SPC f s"]},
         [
           "# Command: save",
           "Description: Save the current file",
           "Keybinding:  SPC f s",
           "Scope:       any"
         ]},
        {%Minga.Command{
           name: :some_command,
           description: "A command",
           execute: fn state -> state end
         }, %{}, ["Keybinding:  none"]},
        {%Minga.Command{
           name: :search_project,
           description: "Search project",
           execute: fn state -> state end
         }, %{search_project: ["SPC s p", "SPC /"]}, ["Keybinding:  SPC s p", "SPC /"]},
        {%Minga.Command{
           name: :agent_abort,
           description: "Stop agent",
           execute: fn state -> state end,
           scope: :agent
         }, %{}, ["Scope:       :agent"]}
      ]

      for {command, keybind_map, expected_fragments} <- cases do
        content = Help.format_describe_command(command, keybind_map)
        for fragment <- expected_fragments, do: assert(content =~ fragment)
      end
    end

    test "describe_command handles registered, unknown, colon-prefixed, and picker-selected commands" do
      state = build_state()

      described =
        Help.execute(state, {:describe_command_named, "describe_bindings"}) |> help_content()

      assert described =~ "# Command: describe_bindings"
      assert described =~ "Description: Describe bindings"
      assert described =~ "Keybinding:  SPC h b"

      colon =
        Help.execute(state, {:describe_command_named, ":describe_bindings"}) |> help_content()

      assert colon =~ "# Command: describe_bindings"

      unknown =
        Help.execute(state, {:describe_command_named, "not_a_real_command_xyz"}) |> help_content()

      assert unknown =~ "Unknown command: not_a_real_command_xyz"

      atom_not_command = Help.execute(state, {:describe_command_named, "true"}) |> help_content()
      assert atom_not_command =~ "Unknown command: true"

      normalized_unknown =
        Help.execute(state, {:describe_command_named, ":not_a_real_command"}) |> help_content()

      assert normalized_unknown =~ "Unknown command: not_a_real_command"
      refute normalized_unknown =~ "Unknown command: :not_a_real_command"

      selected =
        CommandHelpSource.on_select(%Item{id: :describe_bindings, label: ""}, state)
        |> help_content()

      assert selected =~ "# Command: describe_bindings"
      assert selected =~ "Keybinding:  SPC h b"
    end
  end

  describe "help buffer properties" do
    test "help buffer filetype is explicit and resettable" do
      state = build_state()
      markdown = Help.show_in_help_buffer(state, "# Help\n", filetype: :markdown)
      assert BufferProcess.filetype(markdown.workspace.buffers.help) == :markdown
      assert BufferProcess.read_only?(markdown.workspace.buffers.help)

      reset_by_command =
        Help.execute(markdown, {:describe_key_result, "j", :move_down, "Move cursor down"})

      assert BufferProcess.filetype(reset_by_command.workspace.buffers.help) == :text

      reset_by_nil = Help.show_in_help_buffer(markdown, "Plain help\n", filetype: nil)
      assert BufferProcess.filetype(reset_by_nil.workspace.buffers.help) == :text
    end
  end

  describe "describe_lossage" do
    test "opens a read-only *Keystrokes* buffer and reports empty history" do
      result = Help.execute(build_state(), :describe_lossage)
      buffer = result.workspace.buffers.active
      content = BufferProcess.content(buffer)

      assert BufferProcess.buffer_name(buffer) == "*Keystrokes*"
      assert BufferProcess.read_only?(buffer)
      assert content =~ "Keystroke History"
      assert content =~ "No keystrokes recorded yet."
    end

    test "formats keystrokes, mode changes, operator groups, and insert runs" do
      cases = [
        {[
           lossage(key: {?j, 0}, timestamp: 1_715_500_800_000),
           lossage(key: {?k, 0}, timestamp: 1_715_500_801_000)
         ], ["Keystroke History (last 2 keys)", "j", "k"], []},
        {[
           lossage(key: {?j, 0}, timestamp: 1_715_500_800_000),
           lossage(
             key: {?h, 0},
             mode_before: :insert,
             mode_after: :insert,
             timestamp: 1_715_500_802_000
           )
         ], ["── mode: insert ──"], []},
        {[lossage(key: {?i, 0}, mode_before: :normal, mode_after: :insert)], ["→ insert"], []},
        {[
           lossage(
             key: {?d, 0},
             mode_before: :normal,
             mode_after: :operator_pending,
             timestamp: 1_715_500_800_000
           ),
           lossage(
             key: {?w, 0},
             mode_before: :operator_pending,
             mode_after: :normal,
             timestamp: 1_715_500_800_100
           )
         ], ["d w"], []},
        {Enum.map(
           ?a..?c,
           &lossage(
             key: {&1, 0},
             mode_before: :insert,
             mode_after: :insert,
             timestamp: 1_715_500_800_000 + &1
           )
         ), [], ["chars"]},
        {Enum.map(
           ?a..?h,
           &lossage(
             key: {&1, 0},
             mode_before: :insert,
             mode_after: :insert,
             timestamp: 1_715_500_800_000 + &1
           )
         ), ["(8 chars)"], []}
      ]

      for {entries, expected, rejected} <- cases do
        content =
          entries
          |> history_state()
          |> Help.execute(:describe_lossage)
          |> then(&BufferProcess.content(&1.workspace.buffers.active))

        for fragment <- expected, do: assert(content =~ fragment)
        for fragment <- rejected, do: refute(content =~ fragment)
      end
    end
  end

  defp help_content(state), do: BufferProcess.content(state.workspace.buffers.help)

  defp option_item(state, option_name) do
    state
    |> Context.from_editor_state()
    |> OptionSource.candidates()
    |> Enum.find(&(&1.id == option_name))
  end

  defp lossage(opts) do
    %Entry{
      key: Keyword.get(opts, :key, {?j, 0}),
      mode_before: Keyword.get(opts, :mode_before, :normal),
      mode_after: Keyword.get(opts, :mode_after, :normal),
      timestamp: Keyword.get(opts, :timestamp, 1_715_500_800_000)
    }
  end

  defp history_state(entries) do
    history = Enum.reduce(entries, KeystrokeHistory.new(), &KeystrokeHistory.record(&2, &1))
    %{build_state() | keystroke_history: history}
  end
end

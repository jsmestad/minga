defmodule MingaEditor.Commands.HelpTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias MingaEditor.Commands.Help
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.OptionSource
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport

  # ── Test helpers ──────────────────────────────────────────────────────────────

  defp build_state do
    # Start a minimal buffer so add_buffer works
    {:ok, buf} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {BufferServer, content: "hello", buffer_name: "test.txt"}
      )

    {:ok, keymap} = ActiveKeymap.start_link(name: nil)
    {:ok, options} = Minga.Config.Options.start_link(name: nil)

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

  # ── Tests ─────────────────────────────────────────────────────────────────────

  describe "describe_key_result" do
    test "creates *Help* buffer with key description" do
      state = build_state()
      result = Help.execute(state, {:describe_key_result, "j", :move_down, "Move cursor down"})

      assert result.workspace.buffers.help != nil
      assert Process.alive?(result.workspace.buffers.help)

      content = BufferServer.content(result.workspace.buffers.help)
      assert content =~ "Key:         j"
      assert content =~ "Command:     move_down"
      assert content =~ "Description: Move cursor down"
    end

    test "switches to *Help* buffer after describing" do
      state = build_state()
      result = Help.execute(state, {:describe_key_result, "SPC f f", :find_file, "Find file"})

      assert result.workspace.buffers.active == result.workspace.buffers.help
    end

    test "reuses existing *Help* buffer on subsequent calls" do
      state = build_state()
      result1 = Help.execute(state, {:describe_key_result, "j", :move_down, "Move cursor down"})
      help_pid = result1.workspace.buffers.help

      result2 =
        Help.execute(result1, {:describe_key_result, "k", :move_up, "Move cursor up"})

      assert result2.workspace.buffers.help == help_pid

      content = BufferServer.content(help_pid)
      assert content =~ "Command:     move_up"
      refute content =~ "Command:     move_down"
    end

    test "clears status message" do
      state = MingaEditor.State.set_status(build_state(), "Press key to describe:")
      result = Help.execute(state, {:describe_key_result, "j", :move_down, "Move cursor down"})

      assert result.shell_state.status_msg == nil
    end
  end

  describe "describe_key_not_found" do
    test "shows 'Key not bound' in *Help* buffer" do
      state = build_state()
      result = Help.execute(state, {:describe_key_not_found, "z"})

      content = BufferServer.content(result.workspace.buffers.help)
      assert content =~ "Key not bound: z"
    end
  end

  describe "describe_bindings" do
    test "formats leader, normal, text object, and filetype bindings" do
      state = build_state()
      BufferServer.set_filetype(state.workspace.buffers.active, :elixir)

      content = Help.bindings_content(state)

      assert content =~ "+file"
      assert content =~ "SPC f s"
      assert content =~ "save"
      assert content =~ "Movement"
      assert content =~ "w"
      assert content =~ "word_forward"
      assert content =~ "Text objects"
      assert content =~ "iw"
      assert content =~ "+filetype :elixir"
      assert content =~ "SPC m t t"
    end

    test "marks user-defined bindings" do
      state = build_state()

      ActiveKeymap.bind(
        state.keymap_server,
        :normal,
        "SPC x y",
        :custom_command,
        "Custom command"
      )

      content = Help.bindings_content(state)

      assert content =~ "SPC x y"
      assert content =~ "custom_command"
      assert content =~ "*user*"
    end

    test "opens a read-only *Bindings* buffer" do
      state = build_state()
      result = Help.execute(state, :describe_bindings)
      buffer = result.workspace.buffers.active

      assert BufferServer.buffer_name(buffer) == "*Bindings*"
      assert BufferServer.read_only?(buffer)
      assert BufferServer.content(buffer) =~ "# Keybindings"
    end
  end

  describe "describe_option" do
    test "shows option metadata in *Help*" do
      state = build_state()
      result = Help.describe_option(state, :tab_width)

      content = BufferServer.content(result.workspace.buffers.help)
      assert content =~ "# Option: tab_width"
      assert content =~ "Current value: 2"
      assert content =~ "Default: 2"
      assert content =~ "Type: positive integer"
      assert content =~ "Set by: default"
      assert content =~ "Description:"
    end

    test "uses the editor options server for non-buffer-local option values" do
      state = build_state()
      Minga.Config.Options.set(state.options_server, :agent_model, "test-model")

      result = Help.describe_option(state, :agent_model)
      content = BufferServer.content(result.workspace.buffers.help)

      assert content =~ "Current value: \"test-model\""
      assert content =~ "Set by: default → config.exs"
    end

    test "uses filetype-scoped values from the editor options server" do
      state = build_state()
      BufferServer.set_filetype(state.workspace.buffers.active, :go)
      Minga.Config.Options.set_for_filetype(state.options_server, :go, :agent_model, "go-model")

      result = Help.describe_option(state, :agent_model)
      content = BufferServer.content(result.workspace.buffers.help)

      assert content =~ "Current value: \"go-model\""
      assert content =~ "Set by: default → filetype :go"
    end

    test "includes buffer-local provenance in option help" do
      state = build_state()
      BufferServer.set_option(state.workspace.buffers.active, :tab_width, 6)

      result = Help.describe_option(state, :tab_width)
      content = BufferServer.content(result.workspace.buffers.help)

      assert content =~ "Current value: 6"
      assert content =~ "Set by: default → buffer-local"
    end

    test "option picker uses the editor options server for non-buffer-local values" do
      state = build_state()
      Minga.Config.Options.set(state.options_server, :agent_model, "test-model")
      context = Context.from_editor_state(state)

      item = Enum.find(OptionSource.candidates(context), &(&1.id == :agent_model))

      assert item.description =~ "\"test-model\""
      assert item.annotation == "modified"
    end

    test "option picker falls back to the editor options server if the active buffer died" do
      state = build_state()
      Minga.Config.Options.set(state.options_server, :agent_model, "test-model")
      buffer = state.workspace.buffers.active
      monitor = Process.monitor(buffer)

      GenServer.stop(buffer)
      assert_receive {:DOWN, ^monitor, :process, ^buffer, _reason}

      context = Context.from_editor_state(state)
      item = Enum.find(OptionSource.candidates(context), &(&1.id == :agent_model))

      assert item.description =~ "\"test-model\""
    end

    test "shows extension option metadata" do
      state = build_state()

      Minga.Config.Options.register_extension_schema(
        state.options_server,
        :minga_org,
        [{:conceal, :boolean, true, "Hide markup syntax."}],
        conceal: false
      )

      result = Help.describe_extension_option(state, :minga_org, :conceal)
      content = BufferServer.content(result.workspace.buffers.help)

      assert content =~ "# Option: minga_org.conceal"
      assert content =~ "Current value: false"
      assert content =~ "Set by: default → config.exs"
      assert content =~ "Hide markup syntax."
    end
  end

  describe "*Help* buffer properties" do
    test "help buffer is read-only" do
      state = build_state()
      result = Help.execute(state, {:describe_key_result, "j", :move_down, "Move cursor down"})

      assert BufferServer.read_only?(result.workspace.buffers.help)
    end
  end

  describe "describe_lossage" do
    alias MingaEditor.KeystrokeHistory
    alias MingaEditor.KeystrokeHistory.Entry

    defp make_lossage_entry(opts) do
      %Entry{
        key: Keyword.get(opts, :key, {?j, 0}),
        mode_before: Keyword.get(opts, :mode_before, :normal),
        mode_after: Keyword.get(opts, :mode_after, :normal),
        timestamp: Keyword.get(opts, :timestamp, 1_715_500_800_000)
      }
    end

    test "creates *Keystrokes* buffer with empty history message" do
      state = build_state()
      result = Help.execute(state, :describe_lossage)

      buf = result.workspace.buffers.active
      assert Process.alive?(buf)
      assert BufferServer.buffer_name(buf) == "*Keystrokes*"

      content = BufferServer.content(buf)
      assert content =~ "Keystroke History"
      assert content =~ "No keystrokes recorded yet."
    end

    test "*Keystrokes* buffer is read-only" do
      state = build_state()
      result = Help.execute(state, :describe_lossage)

      buf = result.workspace.buffers.active
      assert BufferServer.read_only?(buf)
    end

    test "shows formatted keystrokes when history has entries" do
      state = build_state()

      history =
        KeystrokeHistory.new()
        |> KeystrokeHistory.record(make_lossage_entry(key: {?j, 0}, timestamp: 1_715_500_800_000))
        |> KeystrokeHistory.record(make_lossage_entry(key: {?k, 0}, timestamp: 1_715_500_801_000))

      state = %{state | keystroke_history: history}
      result = Help.execute(state, :describe_lossage)

      content = BufferServer.content(result.workspace.buffers.active)
      assert content =~ "Keystroke History (last 2 keys)"
      assert content =~ "j"
      assert content =~ "k"
    end

    test "annotates mode transitions between groups" do
      state = build_state()

      history =
        KeystrokeHistory.new()
        |> KeystrokeHistory.record(make_lossage_entry(key: {?j, 0}, timestamp: 1_715_500_800_000))
        |> KeystrokeHistory.record(
          make_lossage_entry(
            key: {?h, 0},
            mode_before: :insert,
            mode_after: :insert,
            timestamp: 1_715_500_802_000
          )
        )

      state = %{state | keystroke_history: history}
      result = Help.execute(state, :describe_lossage)

      content = BufferServer.content(result.workspace.buffers.active)
      assert content =~ "── mode: insert ──"
    end

    test "shows mode change arrow on single entry" do
      state = build_state()

      history =
        KeystrokeHistory.new()
        |> KeystrokeHistory.record(
          make_lossage_entry(key: {?i, 0}, mode_before: :normal, mode_after: :insert)
        )

      state = %{state | keystroke_history: history}
      result = Help.execute(state, :describe_lossage)

      content = BufferServer.content(result.workspace.buffers.active)
      assert content =~ "→ insert"
    end

    test "groups operator-pending sequences" do
      state = build_state()

      history =
        KeystrokeHistory.new()
        |> KeystrokeHistory.record(
          make_lossage_entry(
            key: {?d, 0},
            mode_before: :normal,
            mode_after: :operator_pending,
            timestamp: 1_715_500_800_000
          )
        )
        |> KeystrokeHistory.record(
          make_lossage_entry(
            key: {?w, 0},
            mode_before: :operator_pending,
            mode_after: :normal,
            timestamp: 1_715_500_800_100
          )
        )

      state = %{state | keystroke_history: history}
      result = Help.execute(state, :describe_lossage)

      content = BufferServer.content(result.workspace.buffers.active)
      assert content =~ "d w"
    end

    test "3 insert chars are shown individually, not collapsed" do
      state = build_state()

      entries =
        Enum.map(?a..?c, fn cp ->
          make_lossage_entry(
            key: {cp, 0},
            mode_before: :insert,
            mode_after: :insert,
            timestamp: 1_715_500_800_000 + cp
          )
        end)

      history = Enum.reduce(entries, KeystrokeHistory.new(), &KeystrokeHistory.record(&2, &1))

      state = %{state | keystroke_history: history}
      result = Help.execute(state, :describe_lossage)

      content = BufferServer.content(result.workspace.buffers.active)
      refute content =~ "chars"
    end

    test "4+ insert chars are collapsed into compact display" do
      state = build_state()

      entries =
        Enum.map(?a..?h, fn cp ->
          make_lossage_entry(
            key: {cp, 0},
            mode_before: :insert,
            mode_after: :insert,
            timestamp: 1_715_500_800_000 + cp
          )
        end)

      history = Enum.reduce(entries, KeystrokeHistory.new(), &KeystrokeHistory.record(&2, &1))

      state = %{state | keystroke_history: history}
      result = Help.execute(state, :describe_lossage)

      content = BufferServer.content(result.workspace.buffers.active)
      assert content =~ "(8 chars)"
    end
  end
end

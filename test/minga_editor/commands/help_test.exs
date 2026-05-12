defmodule MingaEditor.Commands.HelpTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias MingaEditor.Commands.Help
  alias MingaEditor.State, as: EditorState
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

    test "includes buffer-local provenance in option help" do
      state = build_state()
      BufferServer.set_option(state.workspace.buffers.active, :tab_width, 6)

      result = Help.describe_option(state, :tab_width)
      content = BufferServer.content(result.workspace.buffers.help)

      assert content =~ "Current value: 6"
      assert content =~ "Set by: default → buffer-local"
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
end

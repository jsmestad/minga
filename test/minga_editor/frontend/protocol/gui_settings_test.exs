defmodule MingaEditor.Frontend.Protocol.GUISettingsTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Options
  alias Minga.Frontend.Adapter.GUI.ConfigStateEncoder
  alias MingaEditor.RenderModel.UI.ConfigStateBuilder
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias Minga.Keymap.Active
  alias Minga.Keymap.Scope

  describe "settings gui_actions" do
    test "decodes config_query" do
      assert {:ok, {:gui_action, :config_query}} = Protocol.decode_event(<<0x07, 0x44>>)
    end

    test "decodes typed config_update without creating atoms" do
      payload = <<0x07, 0x43, 5, "theme", 0x04, 0, 8, "doom_one">>

      assert {:ok, {:gui_action, {:config_update, :theme, :doom_one}}} =
               Protocol.decode_event(payload)
    end

    test "decodes boolean integer and string config_update values" do
      assert {:ok, {:gui_action, {:config_update, :wrap, true}}} =
               Protocol.decode_event(<<0x07, 0x43, 4, "wrap", 0x01, 1>>)

      assert {:ok, {:gui_action, {:config_update, :tab_width, 4}}} =
               Protocol.decode_event(<<0x07, 0x43, 9, "tab_width", 0x02, 4::32-signed>>)

      assert {:ok, {:gui_action, {:config_update, :font_family, "Iosevka"}}} =
               Protocol.decode_event(<<0x07, 0x43, 11, "font_family", 0x03, 7::16, "Iosevka">>)
    end

    test "rejects config_update for options outside the settings panel allowlist" do
      key = "confirm_quit"
      payload = <<0x07, 0x43, byte_size(key)::8, key::binary, 0x01, 0>>

      assert {:error, :malformed} = Protocol.decode_event(payload)
    end

    test "rejects unknown config option names" do
      payload = <<0x07, 0x43, 7, "unknown", 0x01, 1>>

      assert {:error, :malformed} = Protocol.decode_event(payload)
    end
  end

  describe "gui_config_state" do
    test "encodes options, theme previews, and keybindings in a length-prefixed envelope" do
      state = %{
        options: %{theme: :doom_one, font_size: 13, wrap: false},
        theme_previews: [
          %{
            name: "Doom One",
            atom: "doom_one",
            editor_bg: 0x282C34,
            editor_fg: 0xBBC2CF,
            accent: 0x51AFEF
          }
        ],
        keybindings: [
          %{mode: "editor", key: "SPC f f", command: "find_file", description: "Find file"}
        ]
      }

      encoded = state |> ConfigStateBuilder.from_wire() |> ConfigStateEncoder.encode_command()

      assert <<0x97, payload_len::16, payload::binary>> = encoded
      assert payload_len == byte_size(payload)
      assert <<3::16, _rest::binary>> = payload
      assert encoded =~ "doom_one"
      assert encoded =~ "Doom One"
      assert encoded =~ "SPC f f"
    end

    test "built settings state includes current editor and leader keybindings" do
      {:ok, options} = Options.start_link(name: nil)

      state = ProtocolGUI.config_state(options, :missing_keymap_server)

      assert Enum.any?(state.keybindings, fn entry ->
               entry.mode == "normal" and entry.key == "SPC f f" and
                 entry.command == "find_file"
             end)

      assert Enum.any?(state.keybindings, fn entry ->
               entry.mode == "normal" and entry.key == "j" and entry.command == "move_down"
             end)
    end

    test "semantic option order is canonical rather than the VM's atom-map order" do
      state =
        ConfigStateBuilder.from_wire(%{
          options: %{wrap: false, theme: :minga_default, cursorline: true},
          theme_previews: [],
          keybindings: []
        })

      assert state.options == [{"cursorline", true}, {"theme", :minga_default}, {"wrap", false}]
    end

    test "settings use the supplied keymap owner's scope declarations, not the global catalog" do
      options = start_supervised!({Options, name: nil})
      keymaps = start_supervised!({Active, name: nil, scope_modules: []})
      state = ProtocolGUI.config_state(options, keymaps)

      assert Active.scope_declarations(keymaps) == %{}
      refute Enum.any?(state.keybindings, &String.contains?(&1.mode, "/"))
      assert Enum.any?(state.keybindings, &(&1.command == "find_file"))
    end

    test "private base settings ignore other owners' contributions and preserve scope source on reset" do
      options = start_supervised!({Options, name: nil})
      scopes = Scope.builtin_modules()
      keymaps = start_supervised!({Active, name: nil, scope_modules: scopes})

      other =
        start_supervised!(
          Supervisor.child_spec({Active, name: nil, scope_modules: []}, id: make_ref())
        )

      before = ProtocolGUI.config_state(options, keymaps)

      assert :ok = Active.bind(other, :normal, "SPC z z", :move_down, "Other owner's binding")
      assert ProtocolGUI.config_state(options, keymaps) == before

      assert Enum.any?(
               ProtocolGUI.config_state(options, other).keybindings,
               &(&1.key == "SPC z z" and &1.description == "Other owner's binding")
             )

      assert :ok = Active.reset(keymaps)
      assert Active.scope_declarations(keymaps) == Map.new(scopes, &{&1.name(), &1})
      assert ProtocolGUI.config_state(options, keymaps) == before
    end
  end
end

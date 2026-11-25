defmodule Minga.Frontend.Adapter.GUI.MenuBarEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.MenuBarEncoder
  alias Minga.RenderModel.UI.ConfigState

  @op Minga.Protocol.Opcodes.gui_menu_bar()

  @item %{
    path: "f s",
    label: "Save file",
    section: "",
    kind: :command,
    command: "save",
    platform_key: "⌘S"
  }

  test "encodes each item as path, label, section, kind, command and ⌘ key in a len16 envelope" do
    {cmd, _caches} =
      MenuBarEncoder.encode(%ConfigState{options: [], leader_menu: [@item]}, Caches.new())

    item =
      <<3::16, "f s", 9::16, "Save file", 0::16, 0::8, 4::16, "save", byte_size("⌘S")::8,
        "⌘S"::binary>>

    payload = <<1::16, item::binary>>
    assert cmd == <<@op, byte_size(payload)::16, payload::binary>>
  end

  test "an unchanged menu is not re-sent, and no snapshot sends nothing" do
    state = %ConfigState{options: [], leader_menu: [@item]}
    {first, caches} = MenuBarEncoder.encode(state, Caches.new())
    assert first != nil
    assert {nil, _caches} = MenuBarEncoder.encode(state, caches)
    assert {nil, _caches} = MenuBarEncoder.encode(nil, Caches.new())
  end
end

defmodule Minga.Frontend.Adapter.GUI.MenuBarEncoder do
  @moduledoc """
  Encodes the leader keymap the macOS menu bar mirrors (`gui_menu_bar`, docs/GUI_PROTOCOL.md).

  It reads the settings snapshot's `leader_menu`, which changes only at connect and on config reload, and sends it only when it changes.
  """

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.ConfigState

  @op_gui_menu_bar Opcodes.gui_menu_bar()

  @spec encode(ConfigState.t() | nil, Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(nil, %Caches{} = caches), do: {nil, caches}

  def encode(%ConfigState{leader_menu: items}, %Caches{} = caches) do
    fp = :erlang.phash2(items)

    if fp != caches.last_menu_bar_fp do
      {encode_command(items), %{caches | last_menu_bar_fp: fp}}
    else
      {nil, caches}
    end
  end

  @doc "Encodes the menu items as one `gui_menu_bar` command."
  @spec encode_command([ConfigState.menu_item()]) :: binary()
  def encode_command(items) when is_list(items) do
    payload =
      items
      |> Enum.reduce(
        :gui_menu_bar |> Writer.new() |> Writer.uint16(:item_count, Enum.count(items)),
        fn item, writer ->
          writer
          |> Writer.string16(:path, item.path)
          |> Writer.string16(:label, item.label)
          |> Writer.string16(:section, item.section)
          |> Writer.uint8(:kind, if(item.kind == :group, do: 1, else: 0))
          |> Writer.string16(:command, item.command)
          |> Writer.string8(:platform_key, item.platform_key)
        end
      )
      |> Writer.finish()

    :gui_menu_bar
    |> Writer.new()
    |> Writer.append(<<@op_gui_menu_bar>>)
    |> Writer.payload16(:payload, payload)
    |> Writer.finish()
  end
end

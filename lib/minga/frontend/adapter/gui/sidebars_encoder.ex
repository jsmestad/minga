defmodule Minga.Frontend.Adapter.GUI.SidebarsEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Sidebars
  alias Minga.RenderModel.UI.Sidebars.Sidebar

  @op_gui_sidebars Opcodes.gui_sidebars()

  @spec encode(Sidebars.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Sidebars{} = model, %Caches{} = caches) do
    fp = :erlang.phash2({model.sidebars, model.active_id})

    if fp != caches.last_sidebars_fp do
      {encode_command(model), %{caches | last_sidebars_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(Sidebars.t()) :: binary()
  def encode_command(%Sidebars{} = model) do
    sidebars = Enum.sort_by(model.sidebars, & &1.order)

    writer =
      :gui_sidebars
      |> Writer.new()
      |> Writer.append(<<1::8>>)
      |> Writer.uint16(:sidebar_count, Enum.count(sidebars))
      |> Writer.string16(:active_id, model.active_id || "")

    payload =
      sidebars
      |> Enum.reduce(writer, &encode_sidebar_metadata/2)
      |> Writer.finish()

    :gui_sidebars
    |> Writer.new()
    |> Writer.append(<<@op_gui_sidebars>>)
    |> Writer.payload32(:payload, payload)
    |> Writer.finish()
  end

  @spec encode_sidebar_metadata(Sidebar.t(), Writer.t()) :: Writer.t()
  defp encode_sidebar_metadata(%Sidebar{} = sidebar, %Writer{} = writer) do
    flags =
      0
      |> Wire.maybe_flag(sidebar.visible?, 0)
      |> Wire.maybe_flag(sidebar.focused?, 1)

    writer
    |> Writer.string16(:sidebar_id, sidebar.id)
    |> Writer.string16(:sidebar_display_name, sidebar.display_name)
    |> Writer.string16(:sidebar_semantic_kind, sidebar.semantic_kind)
    |> Writer.string16(:sidebar_icon, sidebar.icon || "")
    |> Writer.uint16(:sidebar_order, sidebar.order)
    |> Writer.uint8(:sidebar_flags, flags)
    |> Writer.uint16(:sidebar_preferred_width, sidebar.preferred_width)
    |> Writer.uint16(:sidebar_badge_count, badge_count(sidebar.badge_count))
  end

  @spec badge_count(non_neg_integer() | nil) :: non_neg_integer()
  defp badge_count(count) when is_integer(count), do: count
  defp badge_count(nil), do: Wire.max_u16()
end

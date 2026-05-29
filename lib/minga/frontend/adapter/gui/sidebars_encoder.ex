defmodule Minga.Frontend.Adapter.GUI.SidebarsEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
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
    entries =
      model.sidebars
      |> Enum.sort_by(& &1.order)
      |> Enum.take(Wire.max_u16())
      |> Enum.map(&encode_sidebar_metadata/1)

    payload =
      IO.iodata_to_binary([
        <<1::8, length(entries)::16>>,
        Wire.encode_string16(model.active_id || ""),
        entries
      ])

    <<@op_gui_sidebars, byte_size(payload)::32, payload::binary>>
  end

  @spec encode_sidebar_metadata(Sidebar.t()) :: binary()
  defp encode_sidebar_metadata(%Sidebar{} = sidebar) do
    flags =
      0
      |> Wire.maybe_flag(sidebar.visible?, 0)
      |> Wire.maybe_flag(sidebar.focused?, 1)

    badge_count = badge_count(sidebar.badge_count)

    IO.iodata_to_binary([
      Wire.encode_string16(sidebar.id),
      Wire.encode_string16(sidebar.display_name),
      Wire.encode_string16(sidebar.semantic_kind),
      Wire.encode_string16(sidebar.icon || ""),
      <<Wire.clamp_u16(sidebar.order)::16, flags::8, Wire.clamp_u16(sidebar.preferred_width)::16,
        badge_count::16>>
    ])
  end

  @spec badge_count(non_neg_integer() | nil) :: non_neg_integer()
  defp badge_count(count) when is_integer(count), do: Wire.clamp_u16(count)
  defp badge_count(nil), do: Wire.max_u16()
end

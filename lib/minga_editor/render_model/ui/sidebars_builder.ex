defmodule MingaEditor.RenderModel.UI.SidebarsBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Sidebars
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @spec build(Context.t()) :: Sidebars.t()
  def build(%Context{} = ctx) do
    sidebar_registry = Sidebar.table_for(ctx)
    registered_active = Sidebar.active_left(sidebar_registry)
    raw_sidebars = registered_sidebar_metadata(sidebar_registry)
    active_id = active_sidebar_id(ctx, raw_sidebars, registered_active)
    sidebars = mark_active_sidebar(raw_sidebars, active_id)
    fp = :erlang.phash2({sidebars, active_id})
    encoded = ProtocolGUI.encode_gui_sidebars(sidebars, active_id)

    %Sidebars{encoded: encoded, fingerprint: fp}
  end

  @spec registered_sidebar_metadata(Sidebar.table()) :: [ProtocolGUI.sidebar_metadata()]
  defp registered_sidebar_metadata(sidebar_registry) do
    Sidebar.all(sidebar_registry)
    |> Enum.map(fn sidebar ->
      %{
        id: sidebar.id,
        display_name: sidebar.display_name,
        semantic_kind: sidebar.semantic_kind,
        icon: sidebar.icon,
        order: sidebar.priority,
        visible?: sidebar.visible?,
        focused?: sidebar.focused?,
        preferred_width: sidebar.preferred_width,
        badge_count: sidebar.badge_count || sidebar_badge_count(sidebar.snapshot.rows)
      }
    end)
  end

  @spec sidebar_badge_count([map()]) :: non_neg_integer() | nil
  defp sidebar_badge_count(rows) do
    count = Enum.count(rows, &Map.get(&1, :badge))
    if count == 0, do: nil, else: count
  end

  @spec active_sidebar_id(Context.t(), [ProtocolGUI.sidebar_metadata()], Sidebar.entry() | nil) ::
          String.t()
  defp active_sidebar_id(ctx, sidebars, registered_active) do
    registered_id = active_registered_sidebar_id(sidebars, registered_active)
    preferred_id = (ctx.shell_state || %{}) |> Map.get(:sidebar_active_id)

    case registered_id || sidebar_visible_id(sidebars, preferred_id) do
      id when is_binary(id) -> id
      nil -> fallback_active_sidebar_id(sidebars)
    end
  end

  @spec active_registered_sidebar_id([ProtocolGUI.sidebar_metadata()], Sidebar.entry() | nil) ::
          String.t() | nil
  defp active_registered_sidebar_id(_sidebars, nil), do: nil

  defp active_registered_sidebar_id(sidebars, %{id: id}) do
    sidebar_visible_id(sidebars, id)
  end

  @spec sidebar_visible_id([ProtocolGUI.sidebar_metadata()], String.t() | nil) :: String.t() | nil
  defp sidebar_visible_id(_sidebars, nil), do: nil

  defp sidebar_visible_id(sidebars, id) do
    if Enum.any?(sidebars, fn sidebar -> sidebar.id == id and sidebar.visible? end),
      do: id,
      else: nil
  end

  @spec fallback_active_sidebar_id([ProtocolGUI.sidebar_metadata()]) :: String.t()
  defp fallback_active_sidebar_id(sidebars) do
    focused =
      sidebars
      |> Enum.filter(fn sidebar -> sidebar.visible? and sidebar.focused? end)
      |> Enum.sort_by(& &1.order, :desc)
      |> List.first()

    visible =
      sidebars
      |> Enum.filter(& &1.visible?)
      |> Enum.sort_by(& &1.order, :desc)
      |> List.first()

    case focused || visible do
      %{id: id} -> id
      nil -> ""
    end
  end

  @spec mark_active_sidebar([ProtocolGUI.sidebar_metadata()], String.t()) :: [
          ProtocolGUI.sidebar_metadata()
        ]
  defp mark_active_sidebar(sidebars, active_id) do
    Enum.map(sidebars, fn sidebar ->
      %{sidebar | focused?: sidebar.visible? and sidebar.id == active_id}
    end)
  end
end

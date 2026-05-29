defmodule Minga.Frontend.Adapter.GUI.WorkspacesEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Workspaces
  alias Minga.RenderModel.UI.Workspaces.VisibleTab
  alias Minga.RenderModel.UI.Workspaces.Workspace

  @op_gui_workspaces Opcodes.gui_workspaces()

  @spec encode(Workspaces.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Workspaces{visible?: false}, %Caches{} = caches), do: {nil, caches}

  def encode(%Workspaces{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_workspaces_fp do
      {encode_command(model), %{caches | last_workspaces_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(Workspaces.t()) :: binary()
  def encode_command(%Workspaces{} = model) do
    payload = encode_payload(model)
    <<@op_gui_workspaces, byte_size(payload)::16, payload::binary>>
  end

  @spec fingerprint(Workspaces.t()) :: integer()
  defp fingerprint(%Workspaces{} = model) do
    :erlang.phash2({
      model.active_workspace_id,
      model.mode,
      model.attention_count,
      model.workspaces,
      model.visible_tabs
    })
  end

  @spec encode_payload(Workspaces.t()) :: binary()
  defp encode_payload(%Workspaces{} = model) do
    workspace_budget = Wire.max_u16() - 6 - 2

    {workspace_entries, remaining_budget} =
      Wire.bounded_entries(
        model.workspaces,
        &encode_workspace_summary/1,
        Wire.max_u8(),
        workspace_budget
      )

    {visible_tab_entries, _remaining_budget} =
      Wire.bounded_entries(
        model.visible_tabs,
        &encode_visible_tab/1,
        Wire.max_u16(),
        remaining_budget
      )

    IO.iodata_to_binary([
      <<2::8, model.active_workspace_id::16, encode_workspace_mode(model.mode)::8,
        encode_workspace_flags(model)::8, length(workspace_entries)::8>>,
      workspace_entries,
      <<length(visible_tab_entries)::16>>,
      visible_tab_entries
    ])
  end

  @spec encode_workspace_summary(Workspace.t()) :: binary()
  defp encode_workspace_summary(%Workspace{} = workspace) do
    {r, g, b} = Wire.rgb(workspace.color)
    label_bytes = Wire.utf8_prefix_bytes(workspace.label, 255)
    icon_bytes = Wire.utf8_prefix_bytes(workspace.icon, 255)

    <<workspace.id::16, encode_workspace_kind(workspace.kind)::8,
      encode_agent_status(workspace.status)::8, encode_workspace_entry_flags(workspace)::16, r::8,
      g::8, b::8, workspace.tab_count::16, workspace.draft_count::16,
      workspace.conflict_count::16, workspace.running_background_count::16,
      byte_size(label_bytes)::8, label_bytes::binary, byte_size(icon_bytes)::8,
      icon_bytes::binary>>
  end

  @spec encode_visible_tab(VisibleTab.t()) :: binary()
  defp encode_visible_tab(%VisibleTab{} = tab) do
    icon_bytes = Wire.utf8_prefix_bytes(tab.icon, 255)
    label_bytes = Wire.utf8_prefix_bytes(tab.label, Wire.max_u16())
    path_bytes = Wire.utf8_prefix_bytes(tab.path || "", Wire.max_u16())

    <<tab.id::32, tab.workspace_id::16, encode_tab_kind(tab.kind)::8,
      encode_visible_tab_flags(tab)::16, Wire.path_hash(tab.path)::32, byte_size(icon_bytes)::8,
      icon_bytes::binary, byte_size(label_bytes)::16, label_bytes::binary,
      byte_size(path_bytes)::16, path_bytes::binary, tab.tint_color::32>>
  end

  @spec encode_workspace_mode(Workspaces.mode()) :: non_neg_integer()
  defp encode_workspace_mode(:editor), do: 0
  defp encode_workspace_mode(:agent), do: 1
  defp encode_workspace_mode(:file_tree), do: 2
  defp encode_workspace_mode(:other), do: 3

  @spec encode_workspace_flags(Workspaces.t()) :: non_neg_integer()
  defp encode_workspace_flags(%Workspaces{attention_count: count}) when count > 0, do: 0x01
  defp encode_workspace_flags(%Workspaces{}), do: 0x00

  @spec encode_workspace_kind(Workspace.kind() | VisibleTab.kind()) :: non_neg_integer()
  defp encode_workspace_kind(:manual), do: 0
  defp encode_workspace_kind(:agent), do: 1
  defp encode_workspace_kind(:file), do: 0

  @spec encode_workspace_entry_flags(Workspace.t()) :: non_neg_integer()
  defp encode_workspace_entry_flags(%Workspace{} = workspace) do
    0
    |> maybe_workspace_flag(workspace.attention?, 0x01)
    |> maybe_workspace_flag(workspace.closeable?, 0x02)
  end

  @spec encode_tab_kind(VisibleTab.kind()) :: non_neg_integer()
  defp encode_tab_kind(:file), do: 0

  @spec encode_visible_tab_flags(VisibleTab.t()) :: non_neg_integer()
  defp encode_visible_tab_flags(%VisibleTab{} = tab) do
    0
    |> maybe_workspace_flag(tab.dirty?, 0x01)
    |> maybe_workspace_flag(tab.attention?, 0x02)
    |> maybe_workspace_flag(tab.draft_state == :draft, 0x04)
    |> maybe_workspace_flag(tab.draft_state == :draft_elsewhere, 0x08)
    |> maybe_workspace_flag(tab.draft_state == :conflict, 0x10)
    |> maybe_workspace_flag(tab.pinned?, 0x20)
  end

  @spec maybe_workspace_flag(non_neg_integer(), boolean(), non_neg_integer()) :: non_neg_integer()
  defp maybe_workspace_flag(flags, true, bit), do: flags ||| bit
  defp maybe_workspace_flag(flags, false, _bit), do: flags

  @spec encode_agent_status(Workspace.status()) :: non_neg_integer()
  defp encode_agent_status(:idle), do: 0
  defp encode_agent_status(:thinking), do: 1
  defp encode_agent_status(:tool_executing), do: 2
  defp encode_agent_status(:error), do: 3
  defp encode_agent_status(:plan), do: 4
  defp encode_agent_status(_), do: 0
end

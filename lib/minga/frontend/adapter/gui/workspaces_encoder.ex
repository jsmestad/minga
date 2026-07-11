defmodule Minga.Frontend.Adapter.GUI.WorkspacesEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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
    :gui_workspaces
    |> Writer.new()
    |> Writer.append(<<@op_gui_workspaces>>)
    |> Writer.payload16(:payload, encode_payload(model))
    |> Writer.finish()
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
    writer =
      :gui_workspaces
      |> Writer.new()
      |> Writer.append(<<2::8>>)
      |> Writer.uint16(:active_workspace_id, model.active_workspace_id)
      |> Writer.uint8(:workspace_mode, encode_workspace_mode(model.mode))
      |> Writer.uint8(:workspace_flags, encode_workspace_flags(model))
      |> Writer.uint8(:workspace_count, Enum.count(model.workspaces))

    writer = Enum.reduce(model.workspaces, writer, &encode_workspace_summary/2)
    writer = Writer.uint16(writer, :visible_tab_count, Enum.count(model.visible_tabs))

    model.visible_tabs
    |> Enum.reduce(writer, &encode_visible_tab/2)
    |> Writer.finish()
  end

  @spec encode_workspace_summary(Workspace.t(), Writer.t()) :: Writer.t()
  defp encode_workspace_summary(%Workspace{} = workspace, %Writer{} = writer) do
    writer
    |> Writer.uint16(:workspace_id, workspace.id)
    |> Writer.uint8(:workspace_kind, encode_workspace_kind(workspace.kind))
    |> Writer.uint8(:workspace_agent_status, encode_agent_status(workspace.status))
    |> Writer.uint16(:workspace_entry_flags, encode_workspace_entry_flags(workspace))
    |> Writer.rgb24(:workspace_color, workspace.color)
    |> Writer.uint16(:workspace_tab_count, workspace.tab_count)
    |> Writer.uint16(:workspace_draft_count, workspace.draft_count)
    |> Writer.uint16(:workspace_conflict_count, workspace.conflict_count)
    |> Writer.uint16(:workspace_running_background_count, workspace.running_background_count)
    |> Writer.string8(:workspace_label, workspace.label)
    |> Writer.string8(:workspace_icon, workspace.icon)
  end

  @spec encode_visible_tab(VisibleTab.t(), Writer.t()) :: Writer.t()
  defp encode_visible_tab(%VisibleTab{} = tab, %Writer{} = writer) do
    writer
    |> Writer.uint32(:tab_id, tab.id)
    |> Writer.uint16(:tab_workspace_id, tab.workspace_id)
    |> Writer.uint8(:tab_kind, encode_tab_kind(tab.kind))
    |> Writer.uint16(:tab_flags, encode_visible_tab_flags(tab))
    |> Writer.uint32(:tab_path_hash, Wire.path_hash(tab.path))
    |> Writer.string8(:tab_icon, tab.icon)
    |> Writer.string16(:tab_label, tab.label)
    |> Writer.string16(:tab_path, tab.path || "")
    |> Writer.uint32(:tab_tint_color, tab.tint_color)
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
  defp encode_tab_kind(:agent), do: 1

  @spec encode_visible_tab_flags(VisibleTab.t()) :: non_neg_integer()
  defp encode_visible_tab_flags(%VisibleTab{} = tab) do
    0
    |> maybe_workspace_flag(tab.dirty?, 0x01)
    |> maybe_workspace_flag(tab.attention?, 0x02)
    |> maybe_workspace_flag(tab.draft_state == :draft, 0x04)
    |> maybe_workspace_flag(tab.draft_state == :draft_elsewhere, 0x08)
    |> maybe_workspace_flag(tab.draft_state == :conflict, 0x10)
    |> maybe_workspace_flag(tab.pinned?, 0x20)
    |> maybe_workspace_flag(tab.ephemeral?, 0x40)
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

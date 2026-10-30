defmodule Minga.Frontend.Adapter.GUI.FocusOwnerEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.FocusOwner

  @op_gui_focus_owner Opcodes.gui_focus_owner()

  @spec encode(FocusOwner.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%FocusOwner{} = owner, %Caches{} = caches) do
    fingerprint = :erlang.phash2(owner)
    encode_changed(owner, caches, fingerprint, fingerprint == caches.last_focus_owner_fp)
  end

  defp encode_changed(_owner, caches, _fingerprint, true), do: {nil, caches}

  defp encode_changed(owner, caches, fingerprint, false) do
    responder = responder_byte(owner.responder)
    surface = surface_byte(owner.surface)

    command =
      :gui_focus_owner
      |> Writer.new()
      |> Writer.append(<<@op_gui_focus_owner, 10::16>>)
      |> Writer.uint8(:responder, responder)
      |> Writer.uint8(:surface, surface)
      |> Writer.uint32(:window_id, owner.window_id)
      |> Writer.uint32(:generation, owner.generation)
      |> Writer.finish()

    {command, %{caches | last_focus_owner_fp: fingerprint}}
  end

  defp responder_byte(:editor_view), do: 0
  defp responder_byte(:picker_query), do: 1
  defp responder_byte(:search_query), do: 2
  defp responder_byte(:inline_edit), do: 3

  defp surface_byte(:editor), do: 0
  defp surface_byte(:file_tree), do: 1
  defp surface_byte(:agent), do: 2
  defp surface_byte(:git_status), do: 3
  defp surface_byte(:conflict), do: 4
  defp surface_byte(:inline_edit), do: 5
  defp surface_byte(:inline_ask), do: 6
  defp surface_byte(:prompt), do: 7
  defp surface_byte(:picker), do: 8
  defp surface_byte(:completion), do: 9
  defp surface_byte(:command_completion), do: 10
  defp surface_byte(:search), do: 11
end

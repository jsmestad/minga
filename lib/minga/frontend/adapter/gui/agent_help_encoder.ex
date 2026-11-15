defmodule Minga.Frontend.Adapter.GUI.AgentHelpEncoder do
  @moduledoc "Encodes committed Agent Help without changing chat or composer visibility."

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentHelp

  @command :gui_agent_help
  @opcode Opcodes.gui_agent_help()

  @spec encode(AgentHelp.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%AgentHelp{} = model, %Caches{} = caches) do
    fingerprint = :erlang.phash2(model)

    if fingerprint == caches.last_agent_help_fp do
      {nil, caches}
    else
      command =
        Writer.new(@command)
        |> Writer.uint8(:opcode, @opcode)
        |> Writer.payload32(:payload, encode_payload(model))
        |> Writer.finish()

      {command, %{caches | last_agent_help_fp: fingerprint}}
    end
  end

  @spec encode_payload(AgentHelp.t()) :: binary()
  defp encode_payload(%AgentHelp{visible?: false}), do: <<1, 0>>

  defp encode_payload(%AgentHelp{visible?: true, groups: groups}) do
    Writer.new(@command)
    |> Writer.uint8(:version, 1)
    |> Writer.uint8(:visible, 1)
    |> Writer.uint8(:group_count, length(groups))
    |> Writer.append(Enum.map(groups, &encode_group/1))
    |> Writer.finish()
  end

  @spec encode_group(AgentHelp.group()) :: binary()
  defp encode_group({title, bindings}) do
    Writer.new(@command)
    |> Writer.string16(:group_title, title)
    |> Writer.uint8(:binding_count, length(bindings))
    |> Writer.append(Enum.map(bindings, &encode_binding/1))
    |> Writer.finish()
  end

  @spec encode_binding(AgentHelp.binding()) :: binary()
  defp encode_binding({key, description}) do
    Writer.new(@command)
    |> Writer.string8(:binding_key, key)
    |> Writer.string16(:binding_description, description)
    |> Writer.finish()
  end
end

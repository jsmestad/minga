defmodule Minga.Frontend.Adapter.GUI.SubagentPeekTranscriptEncoder do
  @moduledoc "Emits the child transcript without sharing the parent's resident wire base."

  alias Minga.Frontend.Adapter.GUI.{AgentTranscriptEncoder, AgentTranscriptSentState, Caches}
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.SubagentPeek

  @opcode Opcodes.gui_subagent_peek_transcript()

  @doc "Emits a seed when the selected child changes, or its resident delta otherwise."
  @spec encode(SubagentPeek.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%SubagentPeek{transcript: nil}, %Caches{} = caches),
    do: {nil, %{caches | last_subagent_transcript: nil}}

  def encode(%SubagentPeek{pane: %{token: token}, transcript: transcript}, %Caches{} = caches) do
    previous =
      case caches.last_subagent_transcript do
        {^token, sent} -> sent
        _other -> %AgentTranscriptSentState{}
      end

    {payload, next} = AgentTranscriptEncoder.encode_payload(transcript, previous)
    updated = %{caches | last_subagent_transcript: {token, next}}
    {frame(payload), updated}
  end

  @spec frame(binary() | nil) :: binary() | nil
  defp frame(nil), do: nil

  defp frame(payload) do
    :gui_subagent_peek_transcript
    |> Writer.new()
    |> Writer.uint8(:opcode, @opcode)
    |> Writer.payload32(:payload, payload)
    |> Writer.finish()
  end
end

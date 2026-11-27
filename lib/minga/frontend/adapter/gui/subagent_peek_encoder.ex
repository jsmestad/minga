defmodule Minga.Frontend.Adapter.GUI.SubagentPeekEncoder do
  @moduledoc "Encodes the peek controls and parent Started/report labels separately from transcript rows."

  import Bitwise

  alias Minga.Design.Tokens
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.{Encode, Opcodes}
  alias Minga.RenderModel.UI.SubagentPeek

  @opcode Opcodes.gui_subagent_peek()

  @doc "Emits metadata only when a parent step, pane, or draft changes."
  @spec encode(SubagentPeek.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%SubagentPeek{parent_window_id: nil}, %Caches{last_subagent_peek: nil} = caches),
    do: {nil, caches}

  def encode(%SubagentPeek{} = model, %Caches{} = caches) do
    metadata = %{model | transcript: nil}

    if metadata == caches.last_subagent_peek do
      {nil, caches}
    else
      {encode_command(metadata), %{caches | last_subagent_peek: metadata}}
    end
  end

  @doc "Encodes one frame of peek metadata."
  @spec encode_command(SubagentPeek.t()) :: binary()
  def encode_command(%SubagentPeek{} = model) do
    payload = model |> wire_model() |> Encode.encode_gui_subagent_peek()

    :gui_subagent_peek
    |> Writer.new()
    |> Writer.uint8(:opcode, @opcode)
    |> Writer.payload32(:payload, payload)
    |> Writer.finish()
  end

  @spec wire_model(SubagentPeek.t()) :: map()
  defp wire_model(model) do
    %{
      parent_window_id: model.parent_window_id || 0,
      steps:
        Enum.map(model.steps, fn {id, token, label, report} ->
          %{entry_id: id, token: token, label: label, report: report}
        end),
      panes: wire_panes(model)
    }
  end

  @spec wire_panes(SubagentPeek.t()) :: [map()]
  defp wire_panes(%SubagentPeek{pane: nil}), do: []

  defp wire_panes(%SubagentPeek{pane: pane} = model) do
    {row, column} = pane.cursor

    [
      %{
        window_id: pane.window_id,
        parent_rect: rect(model.parent_rect),
        peek_rect: rect(model.peek_rect),
        token: pane.token,
        parent: pane.parent,
        title: pane.title,
        state: Tokens.state_wire(pane.state),
        elapsed: pane.elapsed,
        index: pane.index,
        siblings:
          Enum.map(pane.siblings, fn {token, title, state} ->
            %{token: token, title: title, state: Tokens.state_wire(state)}
          end),
        brief: pane.brief,
        result: pane.result || "",
        prompt: pane.prompt,
        cursor_row: row,
        cursor_column: column,
        flags:
          flag(pane.focused?, 1) ||| flag(pane.editing?, 2) ||| flag(pane.brief_open?, 4) |||
            flag(pane.sending?, 8) ||| flag(pane.result != nil, 16),
        notice: pane.notice || ""
      }
    ]
  end

  @spec rect(SubagentPeek.rect()) :: map()
  defp rect({row, col, width, height}), do: %{row: row, col: col, width: width, height: height}

  @spec flag(boolean(), pos_integer()) :: non_neg_integer()
  defp flag(true, bit), do: bit
  defp flag(false, _bit), do: 0
end

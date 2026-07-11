defmodule Minga.Frontend.Adapter.GUI.LineSpacingEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.LineSpacing

  @op_gui_line_spacing Opcodes.gui_line_spacing()

  @spec encode(LineSpacing.t() | nil, Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(nil, %Caches{} = caches), do: {nil, caches}

  def encode(%LineSpacing{} = model, %Caches{} = caches) do
    fp = spacing_x100(model.multiplier)

    if fp != caches.last_line_spacing_fp do
      {encode_command(model), %{caches | last_line_spacing_fp: fp}}
    else
      {nil, caches}
    end
  end

  # Forward-compatible 0x90+ envelope: opcode(1) + payload_length(2) +
  # spacing_x100(2). Byte-identical to the legacy out-of-band push so frontends
  # need no change.
  @spec encode_command(LineSpacing.t()) :: binary()
  def encode_command(%LineSpacing{} = model) do
    :gui_line_spacing
    |> Writer.new()
    |> Writer.append(<<@op_gui_line_spacing, 2::16>>)
    |> Writer.uint16(:spacing_x100, spacing_x100(model.multiplier))
    |> Writer.finish()
  end

  @spec spacing_x100(number()) :: non_neg_integer()
  defp spacing_x100(multiplier), do: round(multiplier * 100)
end

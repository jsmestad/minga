defmodule Minga.Frontend.Adapter.GUI.CursorAnimationEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.CursorAnimation

  @op_gui_cursor_animation Opcodes.gui_cursor_animation()

  @spec encode(CursorAnimation.t() | nil, Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(nil, %Caches{} = caches), do: {nil, caches}

  def encode(%CursorAnimation{} = model, %Caches{} = caches) do
    if model.enabled? != caches.last_cursor_animation_fp do
      {encode_command(model), %{caches | last_cursor_animation_fp: model.enabled?}}
    else
      {nil, caches}
    end
  end

  # Forward-compatible 0x90+ envelope: opcode(1) + payload_length(2) +
  # enabled(1). Byte-identical to the legacy out-of-band push.
  @spec encode_command(CursorAnimation.t()) :: binary()
  def encode_command(%CursorAnimation{enabled?: enabled?}) do
    enabled_byte = if enabled?, do: 1, else: 0
    <<@op_gui_cursor_animation, 1::16, enabled_byte::8>>
  end
end

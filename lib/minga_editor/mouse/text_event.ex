defmodule MingaEditor.Mouse.TextEvent do
  @moduledoc "A frontend text-pointer event resolved against an immutable presentation."

  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Window

  @enforce_keys [
    :window_id,
    :presentation_id,
    :row_index,
    :row_id,
    :utf16_offset,
    :button,
    :mods,
    :event_type,
    :click_count,
    :scroll_x,
    :scroll_y
  ]
  defstruct @enforce_keys

  @type scroll_direction :: -1 | 0 | 1
  @type t :: %__MODULE__{
          window_id: Window.id(),
          presentation_id: non_neg_integer(),
          row_index: non_neg_integer(),
          row_id: non_neg_integer(),
          utf16_offset: non_neg_integer(),
          button: Protocol.mouse_button(),
          mods: Protocol.modifiers(),
          event_type: Protocol.mouse_event_type(),
          click_count: pos_integer(),
          scroll_x: scroll_direction(),
          scroll_y: scroll_direction()
        }

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @doc "Returns true when a release intentionally carries no text target."
  @spec targetless_release?(t()) :: boolean()
  def targetless_release?(%__MODULE__{
        event_type: :release,
        presentation_id: 0,
        row_id: 0
      }),
      do: true

  def targetless_release?(%__MODULE__{}), do: false
end

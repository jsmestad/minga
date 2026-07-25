defmodule MingaEditor.RenderPipeline.WindowIntent do
  @moduledoc "Cache-free editor-owned per-window render carrier."

  alias MingaEditor.Window

  @fields [
    :content,
    :viewport,
    :cursor,
    :fold_map,
    :fold_ranges,
    :popup_meta,
    :scroll_velocity,
    :scroll_detach_cursor,
    :scroll_echo_top,
    :authoritative_scroll_seq
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          content: MingaEditor.Window.Content.t(),
          viewport: MingaEditor.Viewport.t(),
          cursor: Minga.Buffer.position(),
          fold_map: MingaEditor.FoldMap.t(),
          fold_ranges: [Minga.Editing.Fold.Range.t()],
          popup_meta: MingaEditor.UI.Popup.Active.t() | nil,
          scroll_velocity: MingaEditor.Window.ScrollVelocity.t(),
          scroll_detach_cursor: Minga.Buffer.position() | nil,
          scroll_echo_top: integer() | nil,
          authoritative_scroll_seq: non_neg_integer()
        }

  @spec from_window(Window.t()) :: t()
  def from_window(%Window{} = window) do
    %__MODULE__{
      content: window.content,
      viewport: window.viewport,
      cursor: window.cursor,
      fold_map: window.fold_map,
      fold_ranges: window.fold_ranges,
      popup_meta: window.popup_meta,
      scroll_velocity: window.scroll_velocity,
      scroll_detach_cursor: window.scroll_detach_cursor,
      scroll_echo_top: window.scroll_echo_top,
      authoritative_scroll_seq: window.authoritative_scroll_seq
    }
  end
end

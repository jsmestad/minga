defmodule MingaEditor.RenderPipeline.WindowIntent do
  @moduledoc "Cache-free editor-owned per-window render carrier."

  alias MingaEditor.Renderer.RenderWindow
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
  @enforce_keys [:content, :viewport]
  defstruct @fields

  @type t :: %__MODULE__{
          content: MingaEditor.Window.Content.t(),
          viewport: MingaEditor.Viewport.t(),
          cursor: Minga.Buffer.position(),
          fold_map: term(),
          fold_ranges: list(),
          popup_meta: term(),
          scroll_velocity: term(),
          scroll_detach_cursor: Minga.Buffer.position() | nil,
          scroll_echo_top: non_neg_integer() | nil,
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

  @doc "Materializes the pipeline's private working window with renderer-owned cache state."
  @spec materialize(Window.id(), t(), MingaEditor.Renderer.WindowCache.t()) :: RenderWindow.t()
  def materialize(id, %__MODULE__{} = carrier, cache) do
    carrier
    |> Map.from_struct()
    |> Map.merge(%{id: id, render_cache: cache})
    |> then(&struct!(RenderWindow, &1))
  end
end

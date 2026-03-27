defmodule Minga.Core.Decorations.BlockDecoration do
  @moduledoc """
  A block decoration: fully custom-rendered lines injected between buffer lines.

  Block decorations produce styled content from a render callback. That content
  is inserted into the display line stream at an anchor position. They scroll
  with the buffer, occupy display rows, and participate in viewport height
  calculations, but have no buffer line number and no gutter.

  This is the equivalent of Zed's `BlockProperties` (message headers, image
  previews, slash command output in the AI chat).

  ## Render callback

  The render callback receives the available width and returns styled content
  in one of three forms:

  - `[{text, style}]` — single-line block (most common: headers, separators)
  - `[[{text, style}]]` — multi-line block (list of segment lists, one per row)
  - `[DisplayList.draw()]` — raw draw tuples for maximum control

  The content renderer normalizes the first two forms into draw tuples
  positioned at the correct screen rows.

  ## Height

  Set `height` to an explicit integer for blocks with a known, stable height.
  Set `height` to `:dynamic` for blocks whose height depends on the render
  callback output. Dynamic heights are resolved by invoking the callback
  during DisplayMap construction. The callback is cached per block per frame,
  so it's only called once regardless of height.
  """

  @enforce_keys [:id, :anchor_line, :placement, :render]
  defstruct id: nil,
            anchor_line: 0,
            placement: :above,
            height: 1,
            render: nil,
            on_click: nil,
            priority: 0,
            group: nil

  @typedoc "Render callback: receives available width, returns styled content."
  @type render_fn :: (width :: pos_integer() -> render_result())

  @typedoc """
  Result from a render callback.

  - `[{text, style}]` — single-line block
  - `[[{text, style}]]` — multi-line block (list of lines, each a list of segments)
  """
  @type render_result ::
          [{String.t(), Minga.Core.Face.t()}] | [[{String.t(), Minga.Core.Face.t()}]]

  @typedoc "Click callback: receives row offset within block and column."
  @type click_fn :: (row :: non_neg_integer(), col :: non_neg_integer() -> :ok) | nil

  @type t :: %__MODULE__{
          id: reference(),
          anchor_line: non_neg_integer(),
          placement: :above | :below,
          height: pos_integer() | :dynamic,
          render: render_fn(),
          on_click: click_fn(),
          priority: integer(),
          group: term() | nil
        }

  @doc """
  Returns the height of the block decoration in display lines.

  For explicit heights, returns the stored value. For `:dynamic` heights,
  invokes the render callback with the given width to determine the height
  from the result.
  """
  @spec resolve_height(t(), pos_integer()) :: pos_integer()
  def resolve_height(%__MODULE__{height: :dynamic, render: render_fn}, width) do
    result = render_fn.(width)
    compute_height(result)
  end

  def resolve_height(%__MODULE__{height: h}, _width) when is_integer(h), do: h

  @doc """
  Normalizes the render callback result into a list of segment lists
  (one per display line).
  """
  @spec normalize_render_result(render_result()) :: [[{String.t(), Minga.Core.Face.t()}]]
  def normalize_render_result([]), do: [[]]

  def normalize_render_result([[_ | _] | _] = multi_line), do: multi_line

  def normalize_render_result([{text, _style} | _] = single_line) when is_binary(text) do
    [single_line]
  end

  def normalize_render_result(_other), do: [[]]

  @spec compute_height(render_result()) :: pos_integer()
  defp compute_height([[_ | _] | _] = multi_line), do: length(multi_line)
  defp compute_height([{text, _} | _]) when is_binary(text), do: 1
  defp compute_height(_), do: 1
end

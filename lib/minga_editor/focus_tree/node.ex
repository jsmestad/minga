defmodule MingaEditor.FocusTree.Node do
  @moduledoc """
  A node in the focus tree: a single visible region.

  Each node owns a rect, a content type tag, an optional input handler
  module, and a list of child nodes (rendered z-order: later children
  paint above earlier ones, so hit-tests prefer later children).

  See `MingaEditor.FocusTree` for the tree shape and traversal API.
  """

  @typedoc "Pixel/cell rect. Same shape as `MingaEditor.Layout.rect/0`."
  @type rect :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc """
  Tag identifying what the node represents. Adding a new content type
  is the integration point when introducing a new region (e.g.,
  `:bottom_panel`, `:hover_popup`). The mouse router pattern-matches
  on this tag to pick a handler.
  """
  @type content_type ::
          :viewport
          | :tab_bar
          | :file_tree
          | :editor_area
          | :window
          | :gutter
          | :buffer_content
          | :modeline
          | :agent_panel
          | :bottom_panel
          | :minibuffer
          | :modal_overlay
          | :hover_popup
          | :signature_help
          | :which_key
          | {:custom, atom()}

  @typedoc "A node in the focus tree."
  @type t :: %__MODULE__{
          content_type: content_type(),
          rect: rect(),
          handler: module() | nil,
          scrollable?: boolean(),
          focusable?: boolean(),
          ref: term(),
          children: [t()]
        }

  @enforce_keys [:content_type, :rect]
  defstruct content_type: nil,
            rect: nil,
            handler: nil,
            scrollable?: false,
            focusable?: false,
            ref: nil,
            children: []

  @doc "Constructs a node with the given content type and rect."
  @spec new(content_type(), rect(), keyword()) :: t()
  def new(content_type, rect, opts \\ []) do
    %__MODULE__{
      content_type: content_type,
      rect: rect,
      handler: Keyword.get(opts, :handler),
      scrollable?: Keyword.get(opts, :scrollable?, false),
      focusable?: Keyword.get(opts, :focusable?, false),
      ref: Keyword.get(opts, :ref),
      children: Keyword.get(opts, :children, [])
    }
  end

  @doc "Returns true when `(row, col)` is inside the node's rect."
  @spec contains?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def contains?(%__MODULE__{rect: {r0, c0, w, h}}, row, col) do
    row >= r0 and row < r0 + h and col >= c0 and col < c0 + w
  end
end

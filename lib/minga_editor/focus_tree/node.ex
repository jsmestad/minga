defmodule MingaEditor.FocusTree.Node do
  @moduledoc """
  A node in the focus tree: one visible region that can receive mouse routing.

  Each node owns a rect, a content type tag, optional input handler module, and children in rendered z-order. Later children paint above earlier children, so hit-tests prefer later children. The `id`, `parent`, `previous_sibling`, and `next_sibling` fields are stable references inside the tree, not parent structs. That keeps the tree acyclic while still letting routing and tests reason about hierarchy.

  See `MingaEditor.FocusTree` for tree construction and traversal.
  """

  @typedoc "Pixel/cell rect. Same shape as `MingaEditor.Layout.rect/0`."
  @type rect :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "Stable node reference inside a focus tree."
  @type id :: term()

  @typedoc "Tag identifying what the node represents."
  @type content_type ::
          :viewport
          | :tab_bar
          | :file_tree
          | :editor_area
          | :window
          | :gutter
          | :buffer_content
          | :modeline
          | :status_bar
          | :agent_panel
          | :agent_chat_window
          | :agent_chat_content
          | :bottom_panel
          | :minibuffer
          | :modal_overlay
          | :picker_backdrop
          | :picker
          | :completion_backdrop
          | :completion_menu
          | :hover_popup
          | :signature_help
          | :which_key
          | {:custom, atom()}

  @typedoc "A node in the focus tree."
  @type t :: %__MODULE__{
          id: id(),
          content_type: content_type(),
          rect: rect(),
          handler: module() | nil,
          scrollable?: boolean(),
          focusable?: boolean(),
          ref: term(),
          parent: id() | nil,
          previous_sibling: id() | nil,
          next_sibling: id() | nil,
          children: [t()]
        }

  @enforce_keys [:id, :content_type, :rect]
  defstruct id: nil,
            content_type: nil,
            rect: nil,
            handler: nil,
            scrollable?: false,
            focusable?: false,
            ref: nil,
            parent: nil,
            previous_sibling: nil,
            next_sibling: nil,
            children: []

  @doc "Constructs a node with the given content type and rect."
  @spec new(content_type(), rect(), keyword()) :: t()
  def new(content_type, rect, opts \\ []) do
    ref = Keyword.get(opts, :ref)

    %__MODULE__{
      id: Keyword.get(opts, :id, default_id(content_type, ref)),
      content_type: content_type,
      rect: rect,
      handler: Keyword.get(opts, :handler),
      scrollable?: Keyword.get(opts, :scrollable?, false),
      focusable?: Keyword.get(opts, :focusable?, false),
      ref: ref,
      parent: Keyword.get(opts, :parent),
      previous_sibling: Keyword.get(opts, :previous_sibling),
      next_sibling: Keyword.get(opts, :next_sibling),
      children: Keyword.get(opts, :children, [])
    }
  end

  @doc "Returns true when `(row, col)` is inside the node's half-open rect."
  @spec contains?(t(), integer(), integer()) :: boolean()
  def contains?(%__MODULE__{rect: {r0, c0, w, h}}, row, col) do
    row >= r0 and row < r0 + h and col >= c0 and col < c0 + w
  end

  @spec default_id(content_type(), term()) :: id()
  defp default_id(content_type, nil) when is_atom(content_type), do: content_type
  defp default_id(content_type, ref) when is_atom(content_type), do: {content_type, ref}
  defp default_id({:custom, tag}, nil), do: {:custom, tag}
  defp default_id({:custom, tag}, ref), do: {{:custom, tag}, ref}
end

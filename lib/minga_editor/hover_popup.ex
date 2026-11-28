defmodule MingaEditor.HoverPopup do
  @moduledoc """
  Immutable lifecycle value for hover content.

  The value owns replacement, dismissal, focus, scrolling, expansion, and the optional open action. `MingaEditor.HoverPopup.Presenter` owns geometry.
  """

  alias MingaAgent.Markdown

  @enforce_keys [:content_lines, :anchor_row, :anchor_col]
  defstruct content_lines: [],
            anchor_row: 0,
            anchor_col: 0,
            scroll_offset: 0,
            focused: false,
            open_action: nil,
            alt_content_lines: nil,
            expanded?: false,
            code_source: nil,
            code_range: nil,
            code_id: nil,
            pending_code: nil,
            compact_code_lines: nil,
            offer_id: nil,
            links: {},
            selected_link: nil

  @type code_source :: %{
          optional(:presentation) => non_neg_integer(),
          optional(:terminal_caret_row) => non_neg_integer() | nil,
          trigger: :cursor | :pointer,
          tab: MingaEditor.State.Tab.id() | nil,
          window: MingaEditor.Window.id(),
          viewport: MingaEditor.Viewport.t(),
          buffer: pid(),
          version: non_neg_integer(),
          position: Minga.Buffer.Document.position(),
          anchor: {non_neg_integer(), non_neg_integer()},
          path: String.t() | nil
        }

  @type code_sections :: {[Markdown.parsed_line()], [Markdown.parsed_line()]}
  @type code_range :: {Minga.Buffer.position(), Minga.Buffer.position()}

  @typedoc "Action available from a focused hover popup."
  @type open_action ::
          atom()
          | {:goto_location, String.t(), non_neg_integer(), non_neg_integer()}
          | {:open_session, String.t(), String.t() | nil}

  @typedoc "A hover popup lifecycle value."
  @type t :: %__MODULE__{
          content_lines: [Markdown.parsed_line()],
          anchor_row: non_neg_integer(),
          anchor_col: non_neg_integer(),
          scroll_offset: non_neg_integer(),
          focused: boolean(),
          open_action: open_action() | nil,
          alt_content_lines: [Markdown.parsed_line()] | nil,
          expanded?: boolean(),
          code_source: code_source() | nil,
          code_range: code_range() | nil,
          code_id: pos_integer() | nil,
          pending_code: {reference(), code_sections()} | nil,
          compact_code_lines: [Markdown.parsed_line()] | nil,
          offer_id: pos_integer() | nil,
          links: tuple(),
          selected_link: pos_integer() | nil
        }

  @doc "Creates hover content anchored at the cursor using pure markdown parsing."
  @spec new(String.t(), non_neg_integer(), non_neg_integer(), keyword()) :: t()
  def new(markdown_text, cursor_row, cursor_col, opts \\ []) do
    alternate =
      case Keyword.get(opts, :expanded) do
        nil -> nil
        expanded_markdown -> Markdown.parse(expanded_markdown)
      end

    from_parsed_lines(Markdown.parse(markdown_text), cursor_row, cursor_col, alternate)
  end

  @doc "Creates a lifecycle value from already parsed presentation content."
  @spec from_parsed_lines(
          [Markdown.parsed_line()],
          non_neg_integer(),
          non_neg_integer(),
          [Markdown.parsed_line()] | nil
        ) :: t()
  def from_parsed_lines(content_lines, cursor_row, cursor_col, alternate \\ nil)
      when is_list(content_lines) and is_integer(cursor_row) and cursor_row >= 0 and
             is_integer(cursor_col) and cursor_col >= 0 and
             (is_list(alternate) or is_nil(alternate)) do
    %__MODULE__{
      content_lines: content_lines,
      anchor_row: cursor_row,
      anchor_col: cursor_col,
      alt_content_lines: alternate,
      offer_id: System.unique_integer([:monotonic, :positive])
    }
  end

  @doc "Binds code hover actions to the observed buffer and source position."
  @spec bind_code(t(), code_source()) :: t()
  def bind_code(%__MODULE__{} = popup, source),
    do: %{popup | code_source: source, code_id: popup.offer_id}

  @doc "Highlights a byte range of the captured source for this popup's lifetime."
  @spec highlight_code(t(), code_range() | nil) :: t()
  def highlight_code(%__MODULE__{} = popup, nil), do: popup
  def highlight_code(%__MODULE__{} = popup, range), do: %{popup | code_range: range}

  @doc "Records the request that can enrich this popup and the local sections it must preserve."
  @spec await_code(t(), reference(), code_sections()) :: t()
  def await_code(%__MODULE__{} = popup, ref, sections) when is_reference(ref),
    do: %{popup | pending_code: {ref, sections}}

  @doc "Installs enriched content, renewing the presented action offer without moving focus or the anchor."
  @spec resolve_code(t(), [Markdown.parsed_line()], [Markdown.parsed_line()] | nil) :: t()
  def resolve_code(%__MODULE__{} = popup, lines, compact \\ nil) do
    %{
      popup
      | content_lines: lines,
        compact_code_lines: compact,
        pending_code: nil,
        offer_id: System.unique_integer([:monotonic, :positive]),
        links: index_links(lines),
        selected_link: nil
    }
  end

  @doc "Returns the preview before focus and the complete document after focus."
  @spec display_lines(t()) :: [Markdown.parsed_line()]
  def display_lines(%__MODULE__{focused: false, compact_code_lines: [_ | _] = lines}), do: lines
  def display_lines(%__MODULE__{content_lines: lines}), do: lines

  @doc "Returns true when the popup can toggle to an expanded view."
  @spec expandable?(t()) :: boolean()
  def expandable?(%__MODULE__{alt_content_lines: nil}), do: false
  def expandable?(%__MODULE__{alt_content_lines: _lines}), do: true

  @doc "Toggles between collapsed and expanded content, resetting scroll."
  @spec toggle_expand(t()) :: t()
  def toggle_expand(%__MODULE__{alt_content_lines: nil} = popup), do: popup

  def toggle_expand(%__MODULE__{content_lines: shown, alt_content_lines: alternate} = popup) do
    %{
      popup
      | content_lines: alternate,
        alt_content_lines: shown,
        expanded?: not popup.expanded?,
        scroll_offset: 0
    }
  end

  @doc "Replaces any prior popup value with newly produced hover content."
  @spec replace(t() | nil, t()) :: t()
  def replace(_current, %__MODULE__{} = popup), do: popup

  @doc "Dismisses hover content."
  @spec dismiss(t() | nil) :: nil
  def dismiss(_popup), do: nil

  @doc "Focuses the hover popup for scrolling."
  @spec focus(t()) :: t()
  def focus(%__MODULE__{} = popup), do: %{popup | focused: true}

  @doc "Moves selection to the next or previous link, bringing its line into view."
  @spec select_link(t(), :next | :previous) :: t()
  def select_link(%__MODULE__{links: {}} = popup, _direction), do: popup

  def select_link(%__MODULE__{focused: true} = popup, direction) do
    count = tuple_size(popup.links)

    index =
      case {popup.selected_link, direction} do
        {nil, :next} -> 0
        {nil, :previous} -> count - 1
        {id, :next} -> Integer.mod(id - 1, count)
        {id, :previous} -> Integer.mod(id - 3, count)
      end

    {row, _url} = elem(popup.links, index)
    %{popup | selected_link: index + 2, scroll_offset: row}
  end

  def select_link(%__MODULE__{} = popup, _direction), do: popup

  @doc "Resolves a documentation link by its action ID within this offer."
  @spec link_at(t(), non_neg_integer()) :: String.t() | nil
  def link_at(%__MODULE__{links: links}, id) when id >= 2 and id - 2 < tuple_size(links),
    do: elem(elem(links, id - 2), 1)

  def link_at(%__MODULE__{}, _id), do: nil

  @spec index_links([Markdown.parsed_line()]) :: tuple()
  defp index_links(lines) do
    {links, _row} =
      Enum.reduce(lines, {[], 0}, fn {segments, _kind}, {links, row} ->
        links =
          Enum.reduce(segments, links, fn
            {_label, {:link, url}}, links -> [{row, url} | links]
            _non_link, links -> links
          end)

        {links, row + 1}
      end)

    links |> Enum.reverse() |> Enum.take(65_534) |> List.to_tuple()
  end

  @doc "Sets the action to execute when the popup's Open action is accepted."
  @spec with_open_action(t(), open_action()) :: t()
  def with_open_action(%__MODULE__{} = popup, action) when is_atom(action) do
    %{popup | open_action: action}
  end

  def with_open_action(%__MODULE__{} = popup, {:goto_location, uri, line, col} = action)
      when is_binary(uri) and is_integer(line) and line >= 0 and is_integer(col) and col >= 0 do
    %{popup | open_action: action}
  end

  def with_open_action(%__MODULE__{} = popup, {:open_session, session_id, tool_call_id} = action)
      when is_binary(session_id) and (is_binary(tool_call_id) or is_nil(tool_call_id)) do
    %{popup | open_action: action}
  end

  @doc "Returns true when the popup exposes an Open action."
  @spec open_action?(t()) :: boolean()
  def open_action?(%__MODULE__{open_action: nil}), do: false
  def open_action?(%__MODULE__{open_action: _action}), do: true

  @doc "Returns the user-visible label for the popup's direct action."
  @spec open_action_label(open_action() | nil) :: String.t() | nil
  def open_action_label(nil), do: nil
  def open_action_label({:open_session, _session_id, _tool_call_id}), do: "↩ conversation"
  def open_action_label({:goto_location, _uri, _line, _col}), do: "Open location"
  def open_action_label(action) when is_atom(action), do: "Open"

  @doc "Returns the complete displayed document as plain text, regardless of scroll."
  @spec copy_text(t()) :: String.t()
  def copy_text(%__MODULE__{pending_code: {_ref, {[], []}}}), do: ""

  def copy_text(%__MODULE__{content_lines: lines}) do
    Enum.map_join(lines, "\n", fn {segments, _type} ->
      Enum.map_join(segments, "", fn {text, _style} -> text end)
    end)
  end

  @doc "Scrolls content down by three lines."
  @spec scroll_down(t()) :: t()
  def scroll_down(%__MODULE__{} = popup) do
    max_offset = max(length(display_lines(popup)) - 3, popup.scroll_offset)
    %{popup | scroll_offset: min(popup.scroll_offset + 3, max_offset), selected_link: nil}
  end

  @doc "Scrolls content up by three lines."
  @spec scroll_up(t()) :: t()
  def scroll_up(%__MODULE__{} = popup) do
    %{popup | scroll_offset: max(popup.scroll_offset - 3, 0), selected_link: nil}
  end
end

defmodule MingaEditor.HoverPopup do
  @moduledoc """
  Immutable lifecycle value for hover content.

  The value owns replacement, dismissal, focus, scrolling, expansion, and the optional open action. `MingaEditor.HoverPopup.Presenter` owns geometry and display-list construction.
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
            expanded?: false

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
          expanded?: boolean()
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
      alt_content_lines: alternate
    }
  end

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

  @doc "Returns a stable action name for native frontend metadata."
  @spec open_action_name(open_action() | nil) :: String.t()
  def open_action_name(nil), do: ""
  def open_action_name(action) when is_atom(action), do: Atom.to_string(action)
  def open_action_name({:goto_location, _uri, _line, _col}), do: "goto_location"
  def open_action_name({:open_session, _session_id, _tool_call_id}), do: "open_session"

  @doc "Scrolls content down by three lines."
  @spec scroll_down(t()) :: t()
  def scroll_down(%__MODULE__{} = popup) do
    max_offset = max(Enum.count(popup.content_lines) - 3, 0)
    %{popup | scroll_offset: min(popup.scroll_offset + 3, max_offset)}
  end

  @doc "Scrolls content up by three lines."
  @spec scroll_up(t()) :: t()
  def scroll_up(%__MODULE__{} = popup) do
    %{popup | scroll_offset: max(popup.scroll_offset - 3, 0)}
  end
end

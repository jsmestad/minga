defmodule Minga.Agent.UIState do
  @moduledoc """
  Unified agent UI state wrapping `Panel` and `View` sub-structs.

  `Panel` holds prompt editing and chat display state (buffer, history,
  scroll, model config, paste blocks). `View` holds layout, search,
  preview, toasts, and diff baselines. Splitting into sub-structs keeps
  each under 16 fields while providing a single access point on
  `EditorState.agent_ui`.

  Most callers use the functions on this module (routed through
  `AgentAccess.update_agent_ui/2`). Input handlers and renderers that
  need read-only field access use `AgentAccess.panel/1` to get the
  `Panel` sub-struct directly.
  """

  alias Minga.Agent.UIState.Panel
  alias Minga.Agent.UIState.View
  alias Minga.Agent.View.Preview
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Windows
  alias Minga.Scroll

  # Re-export sub-struct types for backward compat. New code should
  # reference Panel.paste_block(), View.search_state(), etc. directly.
  @typedoc deprecated: "Use Panel.paste_block() instead"
  @typedoc "A collapsed paste block. Deprecated: use Panel.paste_block()."
  @type paste_block :: Panel.paste_block()

  @typedoc "Vim mode for the input field when focused."
  @type input_mode :: :insert | :normal | :visual | :visual_line | :operator_pending

  @typedoc deprecated: "Use View.focus() instead"
  @typedoc "Which panel has keyboard focus. Deprecated: use View.focus()."
  @type focus :: View.focus()

  @typedoc deprecated: "Use View.prefix() instead"
  @typedoc "Active prefix key. Deprecated: use View.prefix()."
  @type prefix :: View.prefix()

  @typedoc deprecated: "Use View.search_match() instead"
  @typedoc "A search match. Deprecated: use View.search_match()."
  @type search_match :: View.search_match()

  @typedoc deprecated: "Use View.search_state() instead"
  @typedoc "Search state. Deprecated: use View.search_state()."
  @type search_state :: View.search_state()

  @typedoc deprecated: "Use View.toast() instead"
  @typedoc "A notification toast. Deprecated: use View.toast()."
  @type toast :: View.toast()

  @typedoc "Thinking level for models that support extended reasoning."
  @type thinking_level :: String.t()

  @typedoc "Agent UI state wrapping Panel and View sub-structs."
  @type t :: %__MODULE__{
          panel: Panel.t(),
          view: View.t()
        }

  @enforce_keys []
  defstruct panel: %Panel{},
            view: %View{}

  # Placeholder prefix used in input lines to represent a collapsed paste block.
  @paste_placeholder_prefix "\0PASTE:"

  # Minimum number of lines for a paste to be collapsed.
  @paste_collapse_threshold 3

  @doc "Creates a new UIState with default sub-structs."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Prompt buffer lifecycle ─────────────────────────────────────────────

  @doc """
  Ensures a prompt Buffer.Server is running. Starts one if `prompt_buffer`
  is nil or the process is dead.
  """
  @spec ensure_prompt_buffer(t()) :: t()
  def ensure_prompt_buffer(%__MODULE__{panel: %Panel{prompt_buffer: pid} = panel} = state)
      when is_pid(pid) do
    BufferServer.buffer_name(pid)
    state
  catch
    :exit, _ ->
      %{state | panel: start_prompt_buffer(panel, "")}
  end

  def ensure_prompt_buffer(%__MODULE__{panel: panel} = state) do
    %{state | panel: start_prompt_buffer(panel, "")}
  end

  defp start_prompt_buffer(%Panel{} = panel, content) do
    {:ok, pid} = BufferServer.start_link(content: content)
    %{panel | prompt_buffer: pid}
  end

  # ── Accessors (delegate to Panel for buffer reads) ──────────────────────

  @doc """
  Returns the prompt text with paste placeholders substituted.

  This is the text submitted to the LLM. Placeholder tokens are replaced
  with the full paste content from `pasted_blocks`.
  """
  @spec prompt_text(t() | Panel.t()) :: String.t()
  def prompt_text(%__MODULE__{panel: panel}), do: prompt_text(panel)

  def prompt_text(%Panel{prompt_buffer: pid, pasted_blocks: blocks})
      when is_pid(pid) do
    content = BufferServer.content(pid)
    substitute_placeholders(content, blocks)
  end

  def prompt_text(%Panel{}), do: ""

  @doc "Returns the raw input text (with placeholders, not substituted)."
  @spec input_text(t() | Panel.t()) :: String.t()
  def input_text(%__MODULE__{panel: panel}), do: Panel.input_text(panel)
  def input_text(%Panel{} = panel), do: Panel.input_text(panel)

  @doc "Returns the input lines as a list of strings."
  @spec input_lines(t() | Panel.t()) :: [String.t()]
  def input_lines(%__MODULE__{panel: panel}), do: Panel.input_lines(panel)
  def input_lines(%Panel{} = panel), do: Panel.input_lines(panel)

  @doc "Returns the input cursor position as `{line, col}`."
  @spec input_cursor(t() | Panel.t()) :: {non_neg_integer(), non_neg_integer()}
  def input_cursor(%__MODULE__{panel: panel}), do: Panel.input_cursor(panel)
  def input_cursor(%Panel{} = panel), do: Panel.input_cursor(panel)

  @doc "Returns the number of input lines."
  @spec input_line_count(t() | Panel.t()) :: pos_integer()
  def input_line_count(%__MODULE__{panel: panel}), do: Panel.input_line_count(panel)
  def input_line_count(%Panel{} = panel), do: Panel.input_line_count(panel)

  @doc "Returns true if the input is empty (single empty line)."
  @spec input_empty?(t() | Panel.t()) :: boolean()
  def input_empty?(%__MODULE__{panel: panel}), do: Panel.input_empty?(panel)
  def input_empty?(%Panel{} = panel), do: Panel.input_empty?(panel)

  @doc "Toggles panel visibility."
  @spec toggle(t()) :: t()
  def toggle(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | visible: !panel.visible}}
  end

  @doc "Advances the spinner animation frame."
  @spec tick_spinner(t()) :: t()
  def tick_spinner(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | spinner_frame: panel.spinner_frame + 1}}
  end

  # ── Input editing (delegates to Buffer.Server) ──────────────────────────

  @doc "Inserts a character at the cursor position."
  @spec insert_char(t(), String.t()) :: t()
  def insert_char(%__MODULE__{panel: %Panel{prompt_buffer: pid}} = state, char)
      when is_pid(pid) do
    BufferServer.insert_text(pid, char)
    %{state | panel: %{state.panel | history_index: -1}}
  end

  def insert_char(%__MODULE__{} = state, char) do
    state = ensure_prompt_buffer(state)
    insert_char(state, char)
  end

  @doc "Inserts a newline at the cursor, splitting the current line."
  @spec insert_newline(t()) :: t()
  def insert_newline(%__MODULE__{panel: %Panel{prompt_buffer: pid}} = state) when is_pid(pid) do
    BufferServer.insert_text(pid, "\n")
    %{state | panel: %{state.panel | history_index: -1}}
  end

  def insert_newline(%__MODULE__{} = state) do
    state = ensure_prompt_buffer(state)
    insert_newline(state)
  end

  @doc """
  Deletes the character before the cursor.

  At the start of a line (col 0), joins with the previous line.
  At the start of the first line, no-op.
  """
  @spec delete_char(t()) :: t()
  def delete_char(%__MODULE__{panel: %Panel{prompt_buffer: pid}} = state) when is_pid(pid) do
    {line, col} = BufferServer.cursor(pid)

    if line == 0 and col == 0 do
      state
    else
      BufferServer.delete_before(pid)
    end

    %{state | panel: %{state.panel | history_index: -1}}
  end

  def delete_char(%__MODULE__{} = state) do
    state = ensure_prompt_buffer(state)
    delete_char(state)
  end

  @doc "Replaces the input content with the given text. Does not save to history."
  @spec set_prompt_text(t(), String.t()) :: t()
  def set_prompt_text(%__MODULE__{panel: %Panel{prompt_buffer: pid}} = state, text)
      when is_pid(pid) do
    BufferServer.replace_content(pid, text)
    %{state | panel: %{state.panel | pasted_blocks: []}}
  end

  def set_prompt_text(%__MODULE__{} = state, _text), do: state

  @doc "Clears the input (after submission). Saves current text to history first."
  @spec clear_input(t()) :: t()
  def clear_input(%__MODULE__{} = state) do
    state = save_to_history(state)

    if is_pid(state.panel.prompt_buffer) do
      BufferServer.replace_content(state.panel.prompt_buffer, "")
    end

    %{state | panel: %{state.panel | history_index: -1, pasted_blocks: []}}
  end

  # ── Cursor movement ────────────────────────────────────────────────────

  @doc "Moves cursor up within the input. Returns `:at_top` if already on the first line."
  @spec move_cursor_up(t()) :: t() | :at_top
  def move_cursor_up(%__MODULE__{panel: %Panel{prompt_buffer: pid}} = state) when is_pid(pid) do
    {line, _col} = BufferServer.cursor(pid)

    if line == 0 do
      :at_top
    else
      BufferServer.move_cursor(pid, :up)
      state
    end
  end

  def move_cursor_up(%__MODULE__{}), do: :at_top

  @doc "Moves cursor down within the input. Returns `:at_bottom` if already on the last line."
  @spec move_cursor_down(t()) :: t() | :at_bottom
  def move_cursor_down(%__MODULE__{panel: %Panel{prompt_buffer: pid}} = state) when is_pid(pid) do
    {line, _col} = BufferServer.cursor(pid)
    total = BufferServer.line_count(pid)

    if line >= total - 1 do
      :at_bottom
    else
      BufferServer.move_cursor(pid, :down)
      state
    end
  end

  def move_cursor_down(%__MODULE__{}), do: :at_bottom

  # ── Paste handling ────────────────────────────────────────────────────────

  @doc """
  Inserts pasted text into the input.

  For short pastes (fewer than #{@paste_collapse_threshold} lines), the text is
  inserted directly into the buffer. For longer pastes, the text is
  stored in `pasted_blocks` and a placeholder token is inserted at the cursor
  position. The placeholder renders as a compact indicator (e.g. "󰆏 [pasted 23 lines]")
  but `prompt_text/1` substitutes the full content when the prompt is submitted.
  """
  @spec insert_paste(t(), String.t()) :: t()
  def insert_paste(%__MODULE__{} = state, ""), do: state

  def insert_paste(%__MODULE__{panel: %Panel{prompt_buffer: pid}} = state, text)
      when is_pid(pid) do
    # Strip NUL bytes from paste to prevent fake placeholder injection
    clean_text = String.replace(text, "\0", "")
    lines = String.split(clean_text, "\n")
    line_count = length(lines)

    if line_count < @paste_collapse_threshold do
      BufferServer.insert_text(pid, clean_text)
      %{state | panel: %{state.panel | history_index: -1}}
    else
      insert_collapsed_paste(state, clean_text)
    end
  end

  def insert_paste(%__MODULE__{} = state, text) do
    state = ensure_prompt_buffer(state)
    insert_paste(state, text)
  end

  @doc """
  Toggles expand/collapse on the paste block at the current cursor line.
  """
  @spec toggle_paste_expand(t()) :: t()
  def toggle_paste_expand(%__MODULE__{panel: %Panel{prompt_buffer: pid}} = state)
      when is_pid(pid) do
    {cursor_line, _} = BufferServer.cursor(pid)
    lines = input_lines(state)
    current_line = Enum.at(lines, cursor_line)

    case parse_placeholder(current_line) do
      {:ok, block_index} ->
        block = Enum.at(state.panel.pasted_blocks, block_index)
        if block, do: expand_block(state, block_index), else: state

      :not_placeholder ->
        case find_expanded_block_at_cursor(state, cursor_line) do
          {:ok, block_index} -> collapse_block(state, block_index)
          :not_found -> state
        end
    end
  end

  def toggle_paste_expand(%__MODULE__{} = state), do: state

  @doc "Returns true if the given line is a paste placeholder token."
  @spec paste_placeholder?(String.t()) :: boolean()
  def paste_placeholder?(line) do
    String.starts_with?(line, @paste_placeholder_prefix)
  end

  @doc "Returns the paste block index for a placeholder line, or nil if not a placeholder."
  @spec paste_block_index(String.t()) :: non_neg_integer() | nil
  def paste_block_index(line) do
    case parse_placeholder(line) do
      {:ok, index} -> index
      :not_placeholder -> nil
    end
  end

  @doc "Returns the line count for a paste block at the given index."
  @spec paste_block_line_count(t() | [paste_block()], non_neg_integer()) :: non_neg_integer()
  def paste_block_line_count(%__MODULE__{panel: panel}, index) do
    paste_block_line_count(panel.pasted_blocks, index)
  end

  def paste_block_line_count(blocks, index) when is_list(blocks) do
    case Enum.at(blocks, index) do
      %{text: text} -> text |> String.split("\n") |> length()
      nil -> 0
    end
  end

  # ── Prompt history ──────────────────────────────────────────────────────────

  @doc "Saves the current input to prompt history (if non-empty)."
  @spec save_to_history(t()) :: t()
  def save_to_history(%__MODULE__{} = state) do
    text = prompt_text(state)

    if String.trim(text) == "" do
      state
    else
      %{state | panel: %{state.panel | prompt_history: [text | state.panel.prompt_history]}}
    end
  end

  @doc "Recalls the previous prompt from history."
  @spec history_prev(t()) :: t()
  def history_prev(%__MODULE__{panel: %Panel{prompt_history: []}} = state), do: state

  def history_prev(%__MODULE__{panel: panel} = state) when is_pid(panel.prompt_buffer) do
    new_idx = min(panel.history_index + 1, length(panel.prompt_history) - 1)
    text = Enum.at(panel.prompt_history, new_idx)
    BufferServer.replace_content(panel.prompt_buffer, text)
    %{state | panel: %{panel | history_index: new_idx}}
  end

  def history_prev(%__MODULE__{} = state), do: state

  @doc "Recalls the next (more recent) prompt from history."
  @spec history_next(t()) :: t()
  def history_next(%__MODULE__{panel: %Panel{history_index: -1}} = state), do: state

  def history_next(
        %__MODULE__{panel: %Panel{history_index: 0, prompt_buffer: pid} = panel} = state
      )
      when is_pid(pid) do
    BufferServer.replace_content(pid, "")
    %{state | panel: %{panel | history_index: -1}}
  end

  def history_next(%__MODULE__{panel: panel} = state) when is_pid(panel.prompt_buffer) do
    new_idx = panel.history_index - 1
    text = Enum.at(panel.prompt_history, new_idx)
    BufferServer.replace_content(panel.prompt_buffer, text)
    %{state | panel: %{panel | history_index: new_idx}}
  end

  def history_next(%__MODULE__{} = state), do: state

  # ── Scrolling (delegates to Minga.Scroll) ────────────────────────────────

  @doc "Scrolls the content up. Delegates to `Minga.Scroll.scroll_up/2`."
  @spec scroll_up(t(), non_neg_integer()) :: t()
  def scroll_up(%__MODULE__{panel: panel} = state, amount) do
    %{state | panel: %{panel | scroll: Scroll.scroll_up(panel.scroll, amount)}}
  end

  @doc "Scrolls the content down. Delegates to `Minga.Scroll.scroll_down/2`."
  @spec scroll_down(t(), non_neg_integer()) :: t()
  def scroll_down(%__MODULE__{panel: panel} = state, amount) do
    %{state | panel: %{panel | scroll: Scroll.scroll_down(panel.scroll, amount)}}
  end

  @doc "Pins chat to bottom. Delegates to `Minga.Scroll.pin_to_bottom/1`."
  @spec scroll_to_bottom(t()) :: t()
  def scroll_to_bottom(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | scroll: Scroll.pin_to_bottom(panel.scroll)}}
  end

  @doc "Scrolls to top. Delegates to `Minga.Scroll.scroll_to_top/1`."
  @spec scroll_to_top(t()) :: t()
  def scroll_to_top(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | scroll: Scroll.scroll_to_top(panel.scroll)}}
  end

  @doc "No-op. Streaming events call this; renderer handles pinning."
  @spec maybe_auto_scroll(t()) :: t()
  def maybe_auto_scroll(%__MODULE__{} = state), do: state

  @doc "Re-engages auto-scroll. Delegates to `Minga.Scroll.pin_to_bottom/1`."
  @spec engage_auto_scroll(t()) :: t()
  def engage_auto_scroll(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | scroll: Scroll.pin_to_bottom(panel.scroll)}}
  end

  @doc "Sets the input focus state. Entering focus ensures the prompt buffer exists."
  @spec set_input_focused(t(), boolean()) :: t()
  def set_input_focused(%__MODULE__{} = state, true) do
    state = ensure_prompt_buffer(state)
    %{state | panel: %{state.panel | input_focused: true}}
  end

  def set_input_focused(%__MODULE__{} = state, false) do
    %{state | panel: %{state.panel | input_focused: false}}
  end

  @doc """
  Clears the chat display without affecting conversation history.

  Sets `display_start_index` to the given message count so the renderer
  skips all messages before this point. Scrolls to bottom.
  """
  @spec clear_display(t(), non_neg_integer()) :: t()
  def clear_display(%__MODULE__{panel: panel} = state, message_count) do
    %{state | panel: %{panel | display_start_index: message_count, scroll: Scroll.new()}}
  end

  @doc "Clears the input and scrolls to the bottom."
  @spec clear_input_and_scroll(t()) :: t()
  def clear_input_and_scroll(%__MODULE__{} = state) do
    state |> clear_input() |> scroll_to_bottom()
  end

  # ── Model/provider config ──────────────────────────────────────────────────

  @doc "Sets the thinking level."
  @spec set_thinking_level(t(), String.t()) :: t()
  def set_thinking_level(%__MODULE__{panel: panel} = state, level) do
    %{state | panel: %{panel | thinking_level: level}}
  end

  @doc "Sets the provider name."
  @spec set_provider_name(t(), String.t()) :: t()
  def set_provider_name(%__MODULE__{panel: panel} = state, provider) do
    %{state | panel: %{panel | provider_name: provider}}
  end

  @doc "Sets the model name."
  @spec set_model_name(t(), String.t()) :: t()
  def set_model_name(%__MODULE__{panel: panel} = state, model) do
    %{state | panel: %{panel | model_name: model}}
  end

  @doc "Sets the scroll offset to an absolute value. Unpins from bottom."
  @spec set_scroll(t(), non_neg_integer()) :: t()
  def set_scroll(%__MODULE__{panel: panel} = state, offset)
      when is_integer(offset) and offset >= 0 do
    %{state | panel: %{panel | scroll: Scroll.set_offset(panel.scroll, offset)}}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # View functions (delegate to View sub-struct)
  # ══════════════════════════════════════════════════════════════════════════

  @doc "Activates the view, saving the current window layout."
  @spec activate(t(), Windows.t(), FileTreeState.t()) :: t()
  def activate(%__MODULE__{view: view} = state, windows, file_tree) do
    %{state | view: View.activate(view, windows, file_tree)}
  end

  @doc "Deactivates the view and returns the restored window layout."
  @spec deactivate(t()) :: {t(), Windows.t() | nil, FileTreeState.t() | nil}
  def deactivate(%__MODULE__{view: view} = state) do
    {new_view, saved_windows, saved_file_tree} = View.deactivate(view)
    {%{state | view: new_view}, saved_windows, saved_file_tree}
  end

  @doc "Switches focus to the given panel."
  @spec set_focus(t(), View.focus()) :: t()
  def set_focus(%__MODULE__{view: view} = state, focus) do
    %{state | view: View.set_focus(view, focus)}
  end

  @doc "Scrolls the preview pane down by the given number of lines."
  @spec scroll_viewer_down(t(), pos_integer()) :: t()
  def scroll_viewer_down(%__MODULE__{view: view} = state, amount) do
    %{state | view: View.scroll_viewer_down(view, amount)}
  end

  @doc "Scrolls the preview pane up by the given number of lines, clamped at 0."
  @spec scroll_viewer_up(t(), pos_integer()) :: t()
  def scroll_viewer_up(%__MODULE__{view: view} = state, amount) do
    %{state | view: View.scroll_viewer_up(view, amount)}
  end

  @doc "Scrolls the preview pane to the top (offset 0)."
  @spec scroll_viewer_to_top(t()) :: t()
  def scroll_viewer_to_top(%__MODULE__{view: view} = state) do
    %{state | view: View.scroll_viewer_to_top(view)}
  end

  @doc "Scrolls the preview pane to a large offset (renderer clamps to actual content)."
  @spec scroll_viewer_to_bottom(t()) :: t()
  def scroll_viewer_to_bottom(%__MODULE__{view: view} = state) do
    %{state | view: View.scroll_viewer_to_bottom(view)}
  end

  @doc "Updates the preview state with the given function."
  @spec update_preview(t(), (Preview.t() -> Preview.t())) :: t()
  def update_preview(%__MODULE__{view: view} = state, fun) do
    %{state | view: View.update_preview(view, fun)}
  end

  @doc "Sets the pending prefix for multi-key sequences."
  @spec set_prefix(t(), View.prefix()) :: t()
  def set_prefix(%__MODULE__{view: view} = state, prefix) do
    %{state | view: View.set_prefix(view, prefix)}
  end

  @doc "Clears any pending prefix."
  @spec clear_prefix(t()) :: t()
  def clear_prefix(%__MODULE__{view: view} = state) do
    %{state | view: View.clear_prefix(view)}
  end

  @doc "Toggles the help overlay visibility."
  @spec toggle_help(t()) :: t()
  def toggle_help(%__MODULE__{view: view} = state) do
    %{state | view: View.toggle_help(view)}
  end

  @doc "Dismisses the help overlay."
  @spec dismiss_help(t()) :: t()
  def dismiss_help(%__MODULE__{view: view} = state) do
    %{state | view: View.dismiss_help(view)}
  end

  @doc "Grows the chat panel width by one step (clamped at max)."
  @spec grow_chat(t()) :: t()
  def grow_chat(%__MODULE__{view: view} = state) do
    %{state | view: View.grow_chat(view)}
  end

  @doc "Shrinks the chat panel width by one step (clamped at min)."
  @spec shrink_chat(t()) :: t()
  def shrink_chat(%__MODULE__{view: view} = state) do
    %{state | view: View.shrink_chat(view)}
  end

  @doc "Resets the chat panel width to the configured default."
  @spec reset_split(t()) :: t()
  def reset_split(%__MODULE__{view: view} = state) do
    %{state | view: View.reset_split(view)}
  end

  @doc false
  @doc deprecated: "Use set_prefix/2 and clear_prefix/1 instead"
  @spec set_pending_g(t(), boolean()) :: t()
  def set_pending_g(%__MODULE__{} = state, true), do: set_prefix(state, :g)
  def set_pending_g(%__MODULE__{} = state, false), do: clear_prefix(state)

  @doc false
  @doc deprecated: "Use view.pending_prefix == :g instead"
  @spec pending_g(t()) :: boolean()
  def pending_g(%__MODULE__{view: %View{pending_prefix: :g}}), do: true
  def pending_g(%__MODULE__{}), do: false

  # ── Search (delegate to View) ───────────────────────────────────────────────

  @doc "Starts a search, saving the current scroll position."
  @spec start_search(t(), non_neg_integer()) :: t()
  def start_search(%__MODULE__{view: view} = state, current_scroll) do
    %{state | view: View.start_search(view, current_scroll)}
  end

  @doc "Returns true if search is active."
  @spec searching?(t() | View.t()) :: boolean()
  def searching?(%__MODULE__{view: view}), do: View.searching?(view)
  def searching?(%View{} = view), do: View.searching?(view)

  @doc "Returns true if search input is being typed."
  @spec search_input_active?(t() | View.t()) :: boolean()
  def search_input_active?(%__MODULE__{view: view}), do: View.search_input_active?(view)
  def search_input_active?(%View{} = view), do: View.search_input_active?(view)

  @doc "Updates the search query string."
  @spec update_search_query(t(), String.t()) :: t()
  def update_search_query(%__MODULE__{view: view} = state, query) do
    %{state | view: View.update_search_query(view, query)}
  end

  @doc "Sets search matches and resets current to 0."
  @spec set_search_matches(t(), [View.search_match()]) :: t()
  def set_search_matches(%__MODULE__{view: view} = state, matches) do
    %{state | view: View.set_search_matches(view, matches)}
  end

  @doc "Moves to the next search match."
  @spec next_search_match(t()) :: t()
  def next_search_match(%__MODULE__{view: view} = state) do
    %{state | view: View.next_search_match(view)}
  end

  @doc "Moves to the previous search match."
  @spec prev_search_match(t()) :: t()
  def prev_search_match(%__MODULE__{view: view} = state) do
    %{state | view: View.prev_search_match(view)}
  end

  @doc "Cancels search."
  @spec cancel_search(t()) :: t()
  def cancel_search(%__MODULE__{view: view} = state) do
    %{state | view: View.cancel_search(view)}
  end

  @doc "Confirms search (keeps matches for n/N navigation, disables input)."
  @spec confirm_search(t()) :: t()
  def confirm_search(%__MODULE__{view: view} = state) do
    %{state | view: View.confirm_search(view)}
  end

  @doc "Returns the saved scroll position from before search started."
  @spec search_saved_scroll(t() | View.t()) :: non_neg_integer() | nil
  def search_saved_scroll(%__MODULE__{view: view}), do: View.search_saved_scroll(view)
  def search_saved_scroll(%View{} = view), do: View.search_saved_scroll(view)

  @doc "Returns the search query, or nil if not searching."
  @spec search_query(t() | View.t()) :: String.t() | nil
  def search_query(%__MODULE__{view: view}), do: View.search_query(view)
  def search_query(%View{} = view), do: View.search_query(view)

  # ── Toasts (delegate to View) ───────────────────────────────────────────────

  @doc "Pushes a toast."
  @spec push_toast(t(), String.t(), :info | :warning | :error) :: t()
  def push_toast(%__MODULE__{view: view} = state, message, level) do
    %{state | view: View.push_toast(view, message, level)}
  end

  @doc "Dismisses the current toast."
  @spec dismiss_toast(t()) :: t()
  def dismiss_toast(%__MODULE__{view: view} = state) do
    %{state | view: View.dismiss_toast(view)}
  end

  @doc "Returns true if a toast is currently visible."
  @spec toast_visible?(t() | View.t()) :: boolean()
  def toast_visible?(%__MODULE__{view: view}), do: View.toast_visible?(view)
  def toast_visible?(%View{} = view), do: View.toast_visible?(view)

  @doc "Clears all toasts."
  @spec clear_toasts(t()) :: t()
  def clear_toasts(%__MODULE__{view: view} = state) do
    %{state | view: View.clear_toasts(view)}
  end

  # ── Diff baselines (delegate to View) ───────────────────────────────────────

  @doc "Records the baseline content for a file path (first edit only)."
  @spec record_baseline(t(), String.t(), String.t()) :: t()
  def record_baseline(%__MODULE__{view: view} = state, path, content) do
    %{state | view: View.record_baseline(view, path, content)}
  end

  @doc "Returns the baseline content for a path, or nil if none recorded."
  @spec get_baseline(t() | View.t(), String.t()) :: String.t() | nil
  def get_baseline(%__MODULE__{view: view}, path), do: View.get_baseline(view, path)
  def get_baseline(%View{} = view, path), do: View.get_baseline(view, path)

  @doc "Clears all diff baselines."
  @spec clear_baselines(t()) :: t()
  def clear_baselines(%__MODULE__{view: view} = state) do
    %{state | view: View.clear_baselines(view)}
  end

  # ── Private: paste helpers ───────────────────────────────────────────────

  @spec insert_collapsed_paste(t(), String.t()) :: t()
  defp insert_collapsed_paste(%__MODULE__{panel: panel} = state, text) do
    pid = panel.prompt_buffer
    {cursor_line, cursor_col} = BufferServer.cursor(pid)
    lines = input_lines(state)

    block_index = length(panel.pasted_blocks)
    new_block = %{text: text, expanded: false}
    placeholder = @paste_placeholder_prefix <> Integer.to_string(block_index)

    current = Enum.at(lines, cursor_line)
    {before, after_cursor} = String.split_at(current, cursor_col)

    new_lines = insert_placeholder_lines(lines, cursor_line, before, after_cursor, placeholder)
    new_content = Enum.join(new_lines, "\n")

    placeholder_line_idx = Enum.find_index(new_lines, &(&1 == placeholder))
    new_cursor_line = min(placeholder_line_idx + 1, length(new_lines) - 1)

    new_cursor_col =
      if new_cursor_line > placeholder_line_idx, do: 0, else: String.length(placeholder)

    BufferServer.replace_content(pid, new_content)
    BufferServer.set_cursor(pid, {new_cursor_line, new_cursor_col})

    new_panel = %{panel | pasted_blocks: panel.pasted_blocks ++ [new_block], history_index: -1}
    %{state | panel: new_panel}
  end

  @spec insert_placeholder_lines(
          [String.t()],
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t()
        ) :: [String.t()]
  defp insert_placeholder_lines(lines, cursor_line, "", "", placeholder) do
    List.replace_at(lines, cursor_line, placeholder)
  end

  defp insert_placeholder_lines(lines, cursor_line, "", after_cursor, placeholder) do
    pre = Enum.take(lines, cursor_line)
    post = Enum.drop(lines, cursor_line + 1)
    pre ++ [placeholder, after_cursor] ++ post
  end

  defp insert_placeholder_lines(lines, cursor_line, _before, "", placeholder) do
    pre = Enum.take(lines, cursor_line + 1)
    post = Enum.drop(lines, cursor_line + 1)
    pre ++ [placeholder] ++ post
  end

  defp insert_placeholder_lines(lines, cursor_line, before, after_cursor, placeholder) do
    pre = Enum.take(lines, cursor_line)
    post = Enum.drop(lines, cursor_line + 1)
    pre ++ [before, placeholder, after_cursor] ++ post
  end

  @spec expand_block(t(), non_neg_integer()) :: t()
  defp expand_block(%__MODULE__{panel: panel} = state, block_index) do
    pid = panel.prompt_buffer
    {cursor_line, _} = BufferServer.cursor(pid)
    lines = input_lines(state)
    block = Enum.at(panel.pasted_blocks, block_index)
    placeholder = @paste_placeholder_prefix <> Integer.to_string(block_index)
    placeholder_line_idx = Enum.find_index(lines, &(&1 == placeholder))

    if placeholder_line_idx do
      text_lines = String.split(block.text, "\n")

      new_lines =
        Enum.take(lines, placeholder_line_idx) ++
          text_lines ++
          Enum.drop(lines, placeholder_line_idx + 1)

      new_blocks = List.update_at(panel.pasted_blocks, block_index, &%{&1 | expanded: true})
      expansion = length(text_lines) - 1

      new_cursor_line =
        if cursor_line > placeholder_line_idx, do: cursor_line + expansion, else: cursor_line

      BufferServer.replace_content(pid, Enum.join(new_lines, "\n"))
      BufferServer.set_cursor(pid, {new_cursor_line, 0})

      %{state | panel: %{panel | pasted_blocks: new_blocks}}
    else
      state
    end
  end

  @spec collapse_block(t(), non_neg_integer()) :: t()
  defp collapse_block(%__MODULE__{panel: panel} = state, block_index) do
    pid = panel.prompt_buffer
    {cursor_line, _} = BufferServer.cursor(pid)
    lines = input_lines(state)
    block = Enum.at(panel.pasted_blocks, block_index)
    text_lines = String.split(block.text, "\n")
    text_line_count = length(text_lines)

    start_idx = find_expanded_block_start(lines, text_lines)

    if start_idx do
      placeholder = @paste_placeholder_prefix <> Integer.to_string(block_index)

      new_lines =
        Enum.take(lines, start_idx) ++
          [placeholder] ++
          Enum.drop(lines, start_idx + text_line_count)

      new_blocks = List.update_at(panel.pasted_blocks, block_index, &%{&1 | expanded: false})
      contraction = text_line_count - 1
      new_cursor_line = collapse_cursor_line(cursor_line, start_idx, text_line_count, contraction)

      BufferServer.replace_content(pid, Enum.join(new_lines, "\n"))
      BufferServer.set_cursor(pid, {new_cursor_line, 0})

      %{state | panel: %{panel | pasted_blocks: new_blocks}}
    else
      state
    end
  end

  @spec collapse_cursor_line(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp collapse_cursor_line(cursor_line, start_idx, text_line_count, _contraction)
       when cursor_line >= start_idx and cursor_line < start_idx + text_line_count,
       do: start_idx

  defp collapse_cursor_line(cursor_line, start_idx, text_line_count, contraction)
       when cursor_line >= start_idx + text_line_count,
       do: cursor_line - contraction

  defp collapse_cursor_line(cursor_line, _start_idx, _text_line_count, _contraction),
    do: cursor_line

  @spec find_expanded_block_at_cursor(t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :not_found
  defp find_expanded_block_at_cursor(%__MODULE__{} = state, cursor_line) do
    lines = input_lines(state)

    state.panel.pasted_blocks
    |> Enum.with_index()
    |> Enum.find_value(:not_found, fn {block, index} ->
      if block.expanded do
        expanded_block_contains_cursor?(lines, block, index, cursor_line)
      end
    end)
  end

  @spec expanded_block_contains_cursor?(
          [String.t()],
          paste_block(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, non_neg_integer()} | nil
  defp expanded_block_contains_cursor?(lines, block, index, cursor_line) do
    text_lines = String.split(block.text, "\n")
    start_idx = find_expanded_block_start(lines, text_lines)

    if start_idx do
      end_idx = start_idx + length(text_lines) - 1
      if cursor_line >= start_idx and cursor_line <= end_idx, do: {:ok, index}
    end
  end

  @spec find_expanded_block_start([String.t()], [String.t()]) :: non_neg_integer() | nil
  defp find_expanded_block_start(input_lines_list, text_lines) do
    text_len = length(text_lines)
    max_start = length(input_lines_list) - text_len

    if max_start < 0 do
      nil
    else
      Enum.find(0..max_start, fn start ->
        Enum.slice(input_lines_list, start, text_len) == text_lines
      end)
    end
  end

  @spec parse_placeholder(String.t()) :: {:ok, non_neg_integer()} | :not_placeholder
  defp parse_placeholder(line) do
    case line do
      <<@paste_placeholder_prefix, rest::binary>> when byte_size(rest) > 0 ->
        case Integer.parse(rest) do
          {index, ""} when index >= 0 -> {:ok, index}
          _ -> :not_placeholder
        end

      _ ->
        :not_placeholder
    end
  end

  @spec substitute_placeholders(String.t(), [paste_block()]) :: String.t()
  defp substitute_placeholders(content, blocks) do
    String.split(content, "\n")
    |> Enum.map_join("\n", fn line -> substitute_placeholder(line, blocks) end)
  end

  @spec substitute_placeholder(String.t(), [paste_block()]) :: String.t()
  defp substitute_placeholder(line, blocks) do
    case parse_placeholder(line) do
      {:ok, index} ->
        case Enum.at(blocks, index) do
          %{text: text} -> text
          nil -> line
        end

      :not_placeholder ->
        line
    end
  end
end

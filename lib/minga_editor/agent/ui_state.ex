defmodule MingaEditor.Agent.UIState do
  @moduledoc """
  Unified agent UI state wrapping `Panel` and `View` sub-structs.

  `Panel` holds prompt editing and chat display state (buffer, history,
  scroll, model config, paste blocks). `View` holds layout, search,
  preview, toasts, and edit timeline. Splitting into sub-structs keeps
  each under 16 fields while providing a single access point on
  `EditorState.agent_ui`.

  Most callers use the functions on this module. Input handlers and
  renderers read the focused UI value from the editor workspace.
  """
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Agent.UIState.Compaction
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Windows

  @typedoc "Vim mode for the input field when focused."
  @type input_mode :: :insert | :normal | :visual | :visual_line | :operator_pending

  @typedoc "Thinking level for models that support extended reasoning."
  @type thinking_level :: String.t()

  @typedoc "Agent UI state wrapping Panel and View sub-structs."
  @type t :: %__MODULE__{
          panel: Panel.t(),
          view: View.t()
        }

  defstruct panel: %Panel{},
            view: %View{}

  # Placeholder prefix used in input lines to represent a collapsed paste block.
  @paste_placeholder_prefix "\0PASTE:"

  @doc "Creates a new UIState with credential-aware panel defaults."
  @spec new() :: t()
  def new, do: %__MODULE__{panel: Panel.new()}

  @doc "Attaches the process-backed prompt buffer to this UI value."
  @spec attach_prompt_buffer(t(), pid()) :: t()
  def attach_prompt_buffer(%__MODULE__{panel: panel} = state, pid) when is_pid(pid) do
    %{state | panel: %{panel | prompt_buffer: pid}}
  end

  @doc "Forgets a dead prompt buffer while preserving prompt metadata."
  @spec detach_prompt_buffer(t()) :: t()
  def detach_prompt_buffer(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | prompt_buffer: nil}}
  end

  @doc "Forgets a prompt buffer only when the retiring process owns it."
  @spec retire_prompt_buffer(t(), pid()) :: t()
  def retire_prompt_buffer(%__MODULE__{panel: %{prompt_buffer: pid}} = state, pid) do
    detach_prompt_buffer(state)
  end

  def retire_prompt_buffer(%__MODULE__{} = state, _pid), do: state

  @doc "Records metadata shared by ordinary prompt edits."
  @spec record_prompt_edit(t()) :: t()
  def record_prompt_edit(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | history_index: -1}}
  end

  @doc "Resets prompt history selection and collapsed-paste metadata."
  @spec reset_prompt_metadata(t()) :: t()
  def reset_prompt_metadata(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | history_index: -1, pasted_blocks: []}}
  end

  @doc "Clears collapsed-paste metadata after complete prompt replacement."
  @spec reset_paste_metadata(t()) :: t()
  def reset_paste_metadata(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | pasted_blocks: []}}
  end

  @doc "Records a submitted prompt in newest-first history order."
  @spec remember_prompt(t(), String.t()) :: t()
  def remember_prompt(%__MODULE__{panel: panel} = state, text) when is_binary(text) do
    %{state | panel: %{panel | prompt_history: [text | panel.prompt_history]}}
  end

  @doc "Selects one prompt-history position after the workflow replaces text."
  @spec select_prompt_history(t(), integer()) :: t()
  def select_prompt_history(%__MODULE__{panel: panel} = state, index) when is_integer(index) do
    %{state | panel: %{panel | history_index: index}}
  end

  @doc "Appends one collapsed paste block and marks the prompt as freshly edited."
  @spec append_paste_block(t(), String.t()) :: t()
  def append_paste_block(%__MODULE__{panel: panel} = state, text) when is_binary(text) do
    block = %{text: text, expanded: false}
    blocks = Enum.concat(panel.pasted_blocks, [block])
    %{state | panel: %{panel | pasted_blocks: blocks, history_index: -1}}
  end

  @doc "Records whether a paste block is expanded in the process-backed prompt."
  @spec mark_paste_expanded(t(), non_neg_integer(), boolean()) :: t()
  def mark_paste_expanded(%__MODULE__{panel: panel} = state, index, expanded?)
      when is_integer(index) and index >= 0 and is_boolean(expanded?) do
    blocks = List.update_at(panel.pasted_blocks, index, &%{&1 | expanded: expanded?})
    %{state | panel: %{panel | pasted_blocks: blocks}}
  end

  @doc "Installs a complete panel projection produced by a named Panel transition."
  @spec replace_panel(t(), Panel.t()) :: t()
  def replace_panel(%__MODULE__{} = state, %Panel{} = panel), do: %{state | panel: panel}

  @doc "Installs a complete view projection produced by a named View transition."
  @spec replace_view(t(), View.t()) :: t()
  def replace_view(%__MODULE__{} = state, %View{} = view), do: %{state | view: view}

  @doc "Toggles panel visibility."
  @spec toggle(t()) :: t()
  def toggle(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | visible: !panel.visible}}
  end

  @doc "Clears the active file mention completion."
  @spec clear_mention_completion(t()) :: t()
  def clear_mention_completion(%__MODULE__{panel: panel} = state) do
    %{state | panel: Panel.clear_mention_completion(panel)}
  end

  @doc "Installs the activity produced by an Activity transition."
  @spec replace_activity(t(), Activity.t()) :: t()
  def replace_activity(%__MODULE__{view: view} = state, %Activity{} = activity) do
    %{state | view: View.replace_activity(view, activity)}
  end

  @doc "Installs the timeline produced by an EditTimeline transition."
  @spec replace_edit_timeline(t(), EditTimeline.t()) :: t()
  def replace_edit_timeline(%__MODULE__{view: view} = state, %EditTimeline{} = timeline) do
    %{state | view: View.replace_edit_timeline(view, timeline)}
  end

  @doc "Installs the compaction lifecycle produced by a Compaction transition."
  @spec replace_compaction(t(), Compaction.t()) :: t()
  def replace_compaction(%__MODULE__{view: view} = state, %Compaction{} = compaction) do
    %{state | view: View.replace_compaction(view, compaction)}
  end

  @doc "Marks compaction as no longer running."
  @spec finish_compaction(t()) :: t()
  def finish_compaction(%__MODULE__{view: view} = state) do
    %{state | view: View.finish_compaction(view)}
  end

  @doc "Advances the spinner animation frame."
  @spec tick_spinner(t()) :: t()
  def tick_spinner(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | spinner_frame: panel.spinner_frame + 1}}
  end

  @doc "Returns true if the given line is a paste placeholder token."
  @spec paste_placeholder?(String.t()) :: boolean()
  def paste_placeholder?(line) do
    String.starts_with?(line, @paste_placeholder_prefix)
  end

  @doc "Returns the paste block index for a placeholder line, or nil if not a placeholder."
  @spec paste_block_index(String.t()) :: non_neg_integer() | nil
  def paste_block_index(<<@paste_placeholder_prefix, rest::binary>>) when byte_size(rest) > 0 do
    case Integer.parse(rest) do
      {index, ""} when index >= 0 -> index
      _other -> nil
    end
  end

  def paste_block_index(_line), do: nil

  @doc "Returns the line count for a paste block at the given index."
  @spec paste_block_line_count(t() | [Panel.paste_block()], non_neg_integer()) ::
          non_neg_integer()
  def paste_block_line_count(%__MODULE__{panel: panel}, index) do
    paste_block_line_count(panel.pasted_blocks, index)
  end

  def paste_block_line_count(blocks, index) when is_list(blocks) do
    case Enum.at(blocks, index) do
      %{text: text} -> text |> String.split("\n") |> Enum.count()
      nil -> 0
    end
  end

  # ── Scrolling (delegates to Minga.Editing.Scroll) ────────────────────────────────

  @doc "Records transcript scroll metrics observed during rendering."
  @spec record_scroll_metrics(t(), non_neg_integer(), pos_integer()) :: t()
  def record_scroll_metrics(%__MODULE__{panel: panel} = state, total_lines, visible_height) do
    scroll = Minga.Editing.Scroll.update_metrics(panel.scroll, total_lines, visible_height)
    %{state | panel: Panel.set_scroll(panel, scroll)}
  end

  @doc "Scrolls the content up. Delegates to `Minga.Editing.scroll_up/2`."
  @spec scroll_up(t(), non_neg_integer()) :: t()
  def scroll_up(%__MODULE__{panel: panel} = state, amount) do
    %{state | panel: %{panel | scroll: Minga.Editing.scroll_up(panel.scroll, amount)}}
  end

  @doc "Scrolls the content down. Delegates to `Minga.Editing.scroll_down/2`."
  @spec scroll_down(t(), non_neg_integer()) :: t()
  def scroll_down(%__MODULE__{panel: panel} = state, amount) do
    %{state | panel: %{panel | scroll: Minga.Editing.scroll_down(panel.scroll, amount)}}
  end

  @doc "Pins chat to bottom. Delegates to `Minga.Editing.pin_to_bottom/1`."
  @spec scroll_to_bottom(t()) :: t()
  def scroll_to_bottom(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | scroll: Minga.Editing.pin_to_bottom(panel.scroll)}}
  end

  @doc """
  Sets the chat pin flag without moving the scroll offset.

  Drives the BEAM-authoritative pin state from a frontend that owns its
  transcript scroll locally (#2654 pin intents). `pinned: true` re-follows the
  bottom, `pinned: false` pauses auto-follow, both without disturbing the
  concrete offset a round-trip frontend still relies on.
  """
  @spec set_pinned(t(), boolean()) :: t()
  def set_pinned(%__MODULE__{panel: panel} = state, pinned) when is_boolean(pinned) do
    %{state | panel: %{panel | scroll: Minga.Editing.set_pinned(panel.scroll, pinned)}}
  end

  @doc "Scrolls to top. Delegates to `Minga.Editing.scroll_to_top/1`."
  @spec scroll_to_top(t()) :: t()
  def scroll_to_top(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | scroll: Minga.Editing.scroll_to_top(panel.scroll)}}
  end

  @doc "Re-engages auto-scroll. Delegates to `Minga.Editing.pin_to_bottom/1`."
  @spec engage_auto_scroll(t()) :: t()
  def engage_auto_scroll(%__MODULE__{panel: panel} = state) do
    %{state | panel: %{panel | scroll: Minga.Editing.pin_to_bottom(panel.scroll)}}
  end

  @doc "Records whether prompt input owns focus; buffer attachment belongs to PromptBuffer."
  @spec set_input_focused(t(), boolean()) :: t()
  def set_input_focused(%__MODULE__{panel: panel} = state, focused?) when is_boolean(focused?) do
    %{state | panel: %{panel | input_focused: focused?}}
  end

  @doc """
  Clears the chat display without affecting conversation history.

  Sets `transcript.display_start` to the given message count so the renderer skips all messages before this point. Scrolls to bottom.
  """
  @spec clear_display(t(), non_neg_integer()) :: t()
  def clear_display(%__MODULE__{panel: panel} = state, message_count) do
    panel =
      panel
      |> Panel.set_display_start(message_count)
      |> Panel.set_scroll(Minga.Editing.new_scroll())

    %{state | panel: panel}
  end

  # ── Model/provider config ──────────────────────────────────────────────────

  @doc "Sets the thinking level."
  @spec set_thinking_level(t(), String.t()) :: t()
  def set_thinking_level(%__MODULE__{panel: panel} = state, level) do
    %{state | panel: %{panel | thinking_level: level}}
  end

  @doc "Sets the model name."
  @spec set_model_name(t(), String.t()) :: t()
  def set_model_name(%__MODULE__{panel: panel} = state, model) do
    %{state | panel: Panel.set_model_name(panel, model)}
  end

  @doc "Sets the provider name."
  @spec set_provider_name(t(), String.t()) :: t()
  def set_provider_name(%__MODULE__{panel: panel} = state, provider) do
    %{state | panel: Panel.set_provider_name(panel, provider)}
  end

  @doc "Sets the scroll offset to an absolute value. Unpins from bottom."
  @spec set_scroll(t(), non_neg_integer()) :: t()
  def set_scroll(%__MODULE__{panel: panel} = state, offset)
      when is_integer(offset) and offset >= 0 do
    %{state | panel: %{panel | scroll: Minga.Editing.set_scroll_offset(panel.scroll, offset)}}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # View functions (delegate to View sub-struct)
  # ══════════════════════════════════════════════════════════════════════════

  @doc "Builds a return target from the current editor context."
  @spec return_target(
          pos_integer() | nil,
          pid() | nil,
          Windows.t(),
          FileTreeState.t(),
          Minga.Keymap.Scope.scope_name(),
          boolean()
        ) :: View.return_target()
  def return_target(
        active_tab_id,
        active_buffer,
        windows,
        file_tree,
        keymap_scope,
        prompt_focused
      ) do
    View.return_target(
      active_tab_id,
      active_buffer,
      windows,
      file_tree,
      keymap_scope,
      prompt_focused
    )
  end

  @doc "Activates the view, saving the current window layout."
  @spec activate(t(), Windows.t() | nil, FileTreeState.t() | nil) :: t()
  def activate(%__MODULE__{view: view} = state, windows, file_tree) do
    %{state | view: View.activate(view, windows, file_tree)}
  end

  @doc "Activates the view with a recorded editor return target."
  @spec activate(
          t(),
          Windows.t() | nil,
          FileTreeState.t() | nil,
          View.return_target() | nil
        ) :: t()
  def activate(%__MODULE__{view: view} = state, windows, file_tree, return_target) do
    %{state | view: View.activate(view, windows, file_tree, return_target)}
  end

  @doc "Sets the editor return target."
  @spec set_return_target(t(), View.return_target() | nil) :: t()
  def set_return_target(%__MODULE__{view: view} = state, return_target) do
    %{state | view: View.set_return_target(view, return_target)}
  end

  @doc "Clears the editor return target."
  @spec clear_return_target(t()) :: t()
  def clear_return_target(%__MODULE__{view: view} = state) do
    %{state | view: View.clear_return_target(view)}
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

  @doc "Installs the preview produced by a Preview transition."
  @spec replace_preview(t(), Preview.t()) :: t()
  def replace_preview(%__MODULE__{view: view} = state, %Preview{} = preview) do
    %{state | view: View.replace_preview(view, preview)}
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

  # ── Edit timeline (delegate to View) ────────────────────────────────────────

  @doc "Resets the edit timeline and cleans up file-backed entry snapshots."
  @spec reset_edit_timeline(t()) :: t()
  def reset_edit_timeline(%__MODULE__{view: view} = state) do
    %{state | view: View.reset_edit_timeline(view)}
  end
end

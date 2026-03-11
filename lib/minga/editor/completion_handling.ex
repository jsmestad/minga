defmodule Minga.Editor.CompletionHandling do
  @moduledoc """
  LSP completion accept, filter, trigger, and dismiss logic.

  Extracted from `Minga.Editor` to keep the GenServer module focused on
  orchestration. All functions are pure state transforms.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Completion
  alias Minga.Editor.BufferLifecycle
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.State, as: EditorState

  @doc """
  Accepts the currently selected completion item.

  Routes to insert-text or text-edit depending on the completion type,
  then dismisses the completion popup.
  """
  @spec accept(EditorState.t(), Completion.t()) :: EditorState.t()
  def accept(state, completion) do
    case Completion.accept(completion) do
      nil ->
        dismiss(state)

      {:insert_text, text} ->
        state |> accept_text(completion, text) |> dismiss()

      {:text_edit, edit} ->
        state |> apply_text_edit(edit) |> dismiss()
    end
  end

  @doc """
  Updates or dismisses completion after a key press.

  Called after every key in insert mode. If the mode changed away from
  insert, dismisses completion. Otherwise updates the filter prefix
  and possibly triggers new completion.
  """
  @spec maybe_handle(EditorState.t(), atom(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  def maybe_handle(state, old_mode, codepoint, modifiers) do
    if state.mode == :insert and old_mode == :insert do
      maybe_update(state, codepoint, modifiers)
    else
      dismiss(state)
    end
  end

  @doc """
  Dismisses the active completion popup and resets trigger state.
  """
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(state) do
    new_bridge = CompletionTrigger.dismiss(state.completion_trigger)
    %{state | completion: nil, completion_trigger: new_bridge}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec accept_text(EditorState.t(), Completion.t(), String.t()) :: EditorState.t()
  defp accept_text(%{buffers: %{active: buf}} = state, completion, text)
       when is_pid(buf) do
    {trigger_line, trigger_col} = completion.trigger_position
    {_content, {cursor_line, cursor_col}} = BufferServer.content_and_cursor(buf)

    if cursor_line == trigger_line and cursor_col > trigger_col do
      BufferServer.apply_text_edit(buf, trigger_line, trigger_col, cursor_line, cursor_col, text)
    else
      BufferServer.insert_text(buf, text)
    end

    state |> BufferLifecycle.lsp_buffer_changed() |> BufferLifecycle.git_buffer_changed()
  end

  defp accept_text(state, _completion, _text), do: state

  @spec apply_text_edit(EditorState.t(), Completion.text_edit()) :: EditorState.t()
  defp apply_text_edit(%{buffers: %{active: buf}} = state, edit) when is_pid(buf) do
    BufferServer.apply_text_edit(
      buf,
      edit.range.start_line,
      edit.range.start_col,
      edit.range.end_line,
      edit.range.end_col,
      edit.new_text
    )

    state |> BufferLifecycle.lsp_buffer_changed() |> BufferLifecycle.git_buffer_changed()
  end

  defp apply_text_edit(state, _edit), do: state

  @spec maybe_update(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp maybe_update(state, codepoint, _mods) do
    buf = state.buffers.active
    if buf == nil, do: state, else: do_update(state, buf, codepoint)
  end

  @spec do_update(EditorState.t(), pid(), non_neg_integer()) :: EditorState.t()
  defp do_update(state, buf, codepoint) do
    state = update_filter(state, buf)
    maybe_trigger(state, buf, codepoint)
  end

  @spec update_filter(EditorState.t(), pid()) :: EditorState.t()
  defp update_filter(%{completion: nil} = state, _buf), do: state

  defp update_filter(%{completion: %Completion{} = completion} = state, buf) do
    prefix = completion_prefix(buf, completion.trigger_position)
    apply_filter(state, completion, prefix)
  end

  @spec apply_filter(EditorState.t(), Completion.t(), String.t() | nil) :: EditorState.t()
  defp apply_filter(state, _completion, nil), do: dismiss(state)
  defp apply_filter(state, _completion, ""), do: dismiss(state)

  defp apply_filter(state, completion, prefix) do
    filtered = Completion.filter(completion, prefix)

    if Completion.active?(filtered) do
      %{state | completion: filtered}
    else
      dismiss(state)
    end
  end

  @spec maybe_trigger(EditorState.t(), pid(), non_neg_integer()) :: EditorState.t()
  defp maybe_trigger(state, buf, codepoint) do
    case codepoint_to_char(codepoint) do
      nil ->
        state

      char ->
        {new_bridge, _comp} =
          CompletionTrigger.maybe_trigger(state.completion_trigger, char, buf, state.lsp)

        %{state | completion_trigger: new_bridge}
    end
  end

  @spec completion_prefix(pid(), {non_neg_integer(), non_neg_integer()}) :: String.t() | nil
  defp completion_prefix(buf, {trigger_line, trigger_col}) do
    {content, {cursor_line, cursor_col}} = BufferServer.content_and_cursor(buf)

    if cursor_line == trigger_line and cursor_col >= trigger_col do
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> nil
        line_text -> String.slice(line_text, trigger_col, cursor_col - trigger_col)
      end
    else
      nil
    end
  end

  @doc """
  Handles an LSP completion response.

  Matches the response ref against the pending trigger, creates a
  `Completion` struct if items were returned, and renders.
  """
  @spec handle_response(EditorState.t(), reference(), term()) :: EditorState.t()
  def handle_response(%{buffers: %{active: nil}} = state, _ref, _result), do: state

  def handle_response(state, ref, result) do
    buffer_pid = state.buffers.active

    {new_bridge, completion} =
      CompletionTrigger.handle_response(state.completion_trigger, ref, result, buffer_pid)

    new_state = %{state | completion_trigger: new_bridge}

    case completion do
      nil -> new_state
      %Completion{} -> %{new_state | completion: completion}
    end
  end

  @spec codepoint_to_char(non_neg_integer()) :: String.t() | nil
  defp codepoint_to_char(cp) when cp >= 32 and cp <= 0x10FFFF do
    <<cp::utf8>>
  rescue
    ArgumentError -> nil
  end

  defp codepoint_to_char(_), do: nil
end

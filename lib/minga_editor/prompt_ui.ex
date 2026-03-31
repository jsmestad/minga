defmodule MingaEditor.PromptUI do
  @moduledoc """
  Prompt UI: open, key handling, and close.

  Manages a single-line text input prompt in the minibuffer area. Extensions
  use this for collecting free-form text input (capture titles, rename targets,
  search queries). All functions are pure `state -> state` transformations.

  Prompts and pickers are mutually exclusive: opening a prompt closes any
  active picker, and vice versa.

  ## Usage

      # Open a prompt
      state = PromptUI.open(state, MyCapturePrompt)
      state = PromptUI.open(state, MyCapturePrompt, default: "pre-filled")

      # Keys are routed here when prompt is active
      {state, action} = PromptUI.handle_key(state, key, mods)
  """

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.Prompt, as: PromptState

  @escape 27
  @enter 13
  @backspace 127
  @arrow_left 57_350
  @arrow_right 57_351
  @delete 57_348

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Optional action the GenServer should dispatch after handle_key."
  @type action :: nil

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Opens a text input prompt with the given handler module.

  Closes any active picker first. An optional `:default` value pre-fills
  the input field. An optional `:context` map is stored for the handler
  to read.

  ## Options

  - `:default` — pre-filled text (default: `""`)
  - `:context` — arbitrary map passed through to the handler (default: `nil`)
  """
  @spec open(state(), module(), keyword()) :: state()
  def open(state, handler_module, opts \\ []) do
    default_text = Keyword.get(opts, :default, "")
    context = Keyword.get(opts, :context)
    label = handler_module.label()

    state = maybe_close_picker(state)

    EditorState.set_prompt_ui(state, %PromptState{
      handler: handler_module,
      text: default_text,
      cursor: String.length(default_text),
      label: label,
      context: context
    })
  end

  @doc """
  Closes the prompt without calling any handler callback.
  """
  @spec close(state()) :: state()
  def close(state) do
    EditorState.set_prompt_ui(state, %PromptState{})
  end

  @doc """
  Returns true if a prompt is currently open.
  """
  @spec open?(state()) :: boolean()
  def open?(state), do: PromptState.open?(state.shell_state.prompt_ui)

  @doc """
  Handles a key event while the prompt is active.

  Returns `{state, action}` where action is always nil (prompts don't
  produce deferred actions like the picker does).
  """
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: {state(), action()}
  def handle_key(state, key, _mods) do
    prompt = state.shell_state.prompt_ui

    case key do
      @escape ->
        new_state = prompt.handler.on_cancel(state)
        {close(new_state), nil}

      @enter ->
        new_state = prompt.handler.on_submit(prompt.text, state)
        {close(new_state), nil}

      @backspace ->
        {do_backspace(state, prompt), nil}

      @delete ->
        {do_delete(state, prompt), nil}

      @arrow_left ->
        new_cursor = max(0, prompt.cursor - 1)
        {EditorState.set_prompt_ui(state, %{prompt | cursor: new_cursor}), nil}

      @arrow_right ->
        max_pos = String.length(prompt.text)
        new_cursor = min(max_pos, prompt.cursor + 1)
        {EditorState.set_prompt_ui(state, %{prompt | cursor: new_cursor}), nil}

      _ ->
        {do_insert(state, prompt, key), nil}
    end
  end

  @doc """
  Returns the label and current text for rendering.

  Returns `{label, text, cursor_col}` where cursor_col is the column
  within the text (not including the label width).
  """
  @spec render_data(state()) :: {String.t(), String.t(), non_neg_integer()}
  def render_data(state) do
    prompt = state.shell_state.prompt_ui
    {prompt.label, prompt.text, prompt.cursor}
  end

  @doc """
  Renders the prompt overlay into draw commands and a cursor position.

  Returns `{draws, cursor}` where draws is a list of display list
  draw commands and cursor is a `%Cursor{}` for the input position.
  Returns `{[], nil}` when no prompt is active.
  """
  @spec render(state(), MingaEditor.Viewport.t()) ::
          {[MingaEditor.DisplayList.draw()], {non_neg_integer(), non_neg_integer()} | nil}
  def render(%{shell_state: %{prompt_ui: %PromptState{handler: nil}}}, _viewport), do: {[], nil}

  def render(%{shell_state: %{prompt_ui: prompt}, theme: theme} = _state, viewport) do
    alias MingaEditor.DisplayList
    alias Minga.Core.Face

    pc = theme.picker
    row = viewport.rows - 1
    label = prompt.label
    text = prompt.text
    label_len = String.length(label)

    label_face = Face.new(fg: pc.prompt_fg, bg: pc.prompt_bg)
    input_face = Face.new(fg: pc.fg, bg: pc.bg)

    # Pad to fill the row
    total_len = label_len + String.length(text)
    padding = String.duplicate(" ", max(0, viewport.cols - total_len))

    draws = [
      DisplayList.draw(row, 0, label, label_face),
      DisplayList.draw(row, label_len, text <> padding, input_face)
    ]

    cursor_pos = {row, label_len + prompt.cursor}

    {draws, cursor_pos}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec maybe_close_picker(state()) :: state()
  defp maybe_close_picker(%{shell_state: %{picker_ui: %PickerState{picker: nil}}} = state),
    do: state

  defp maybe_close_picker(state), do: EditorState.set_picker_ui(state, %PickerState{})

  @spec do_backspace(state(), PromptState.t()) :: state()
  defp do_backspace(state, %{cursor: 0} = _prompt), do: state

  defp do_backspace(state, prompt) do
    graphemes = String.graphemes(prompt.text)
    {before, after_} = Enum.split(graphemes, prompt.cursor)
    new_text = Enum.join(Enum.drop(before, -1)) <> Enum.join(after_)
    new_cursor = prompt.cursor - 1
    EditorState.set_prompt_ui(state, %{prompt | text: new_text, cursor: new_cursor})
  end

  @spec do_delete(state(), PromptState.t()) :: state()
  defp do_delete(state, prompt) do
    graphemes = String.graphemes(prompt.text)
    do_delete_grapheme(state, prompt, graphemes)
  end

  @spec do_delete_grapheme(state(), PromptState.t(), [String.t()]) :: state()
  defp do_delete_grapheme(state, %{cursor: cursor}, graphemes)
       when cursor >= length(graphemes),
       do: state

  defp do_delete_grapheme(state, prompt, graphemes) do
    {before, [_deleted | after_]} = Enum.split(graphemes, prompt.cursor)
    new_text = Enum.join(before) <> Enum.join(after_)
    EditorState.set_prompt_ui(state, %{prompt | text: new_text})
  end

  @spec do_insert(state(), PromptState.t(), non_neg_integer()) :: state()
  defp do_insert(state, prompt, key)
       when key >= 32 and key <= 0x10FFFF and not (key >= 0xD800 and key <= 0xDFFF) do
    char = <<key::utf8>>
    graphemes = String.graphemes(prompt.text)
    {before, after_} = Enum.split(graphemes, prompt.cursor)
    new_text = Enum.join(before) <> char <> Enum.join(after_)
    new_cursor = prompt.cursor + 1
    EditorState.set_prompt_ui(state, %{prompt | text: new_text, cursor: new_cursor})
  end

  defp do_insert(state, _prompt, _key), do: state
end

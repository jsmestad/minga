defmodule MingaEditor.PromptUI do
  @moduledoc """
  Prompt UI: open, key handling, and close.

  Manages a single-line text input prompt in the minibuffer area. Extensions
  use this for collecting free-form text input (capture titles, rename targets,
  search queries). All functions are pure `state -> state` transformations.

  Prompts and pickers are mutually exclusive: opening a prompt closes any
  active picker. The replacement is handled automatically by
  `MingaEditor.Shell.Traditional.ModalWorkflow.open/2`.

  ## Usage

      # Open a prompt
      state = PromptUI.open(state, MyCapturePrompt)
      state = PromptUI.open(state, MyCapturePrompt, default: "pre-filled")

      # Keys are routed here when prompt is active
      {state, action} = PromptUI.handle_key(state, key, mods)
  """

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Prompt, as: PromptPayload
  alias MingaEditor.State.Prompt, as: PromptState

  @escape 27
  @enter 13
  @tab 9
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

  Replaces any active modal (the gate's replacement policy handles the
  picker → prompt transition). An optional `:default` value pre-fills the
  input field. An optional `:context` map is stored for the handler to
  read.

  ## Options

  - `:default` — pre-filled text (default: `""`)
  - `:context` — arbitrary map passed through to the handler (default: `nil`)
  - `:label` — prompt label override (default: `handler_module.label()`)
  """
  @spec open(state(), module(), keyword()) :: state()
  def open(state, handler_module, opts \\ []) do
    default_text = Keyword.get(opts, :default, "")
    context = Keyword.get(opts, :context)
    label = Keyword.get(opts, :label, handler_module.label())

    prompt_state = %PromptState{
      handler: handler_module,
      text: default_text,
      cursor: String.length(default_text),
      label: label,
      context: context
    }

    MingaEditor.Shell.Traditional.ModalWorkflow.open(
      state,
      {:prompt, PromptPayload.new(prompt_state)}
    )
  end

  @doc """
  Closes the prompt without calling any handler callback.
  """
  @spec close(state()) :: state()
  def close(state) do
    MingaEditor.Shell.Traditional.ModalWorkflow.dismiss(state)
  end

  @doc """
  Returns true if a prompt is currently open.
  """
  @spec open?(state()) :: boolean()
  def open?(state), do: ModalOverlay.match(state.shell_runtime.state.modal, :prompt)

  @doc """
  Handles a key event while the prompt is active.

  Returns `{state, action}` where action is always nil (prompts don't
  produce deferred actions like the picker does).
  """
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: {state(), action()}
  def handle_key(state, key, _mods) do
    {:prompt, %{prompt_ui: prompt}} = state.shell_runtime.state.modal

    case key do
      @escape ->
        new_state = prompt.handler.on_cancel(state)
        {close(new_state), nil}

      @enter ->
        new_state = prompt.handler.on_submit(prompt.text, state)
        {close(new_state), nil}

      @tab ->
        {do_tab(state, prompt), nil}

      @backspace ->
        {do_backspace(state, prompt), nil}

      @delete ->
        {do_delete(state, prompt), nil}

      @arrow_left ->
        new_cursor = max(0, prompt.cursor - 1)
        {update_prompt(state, &%{&1 | cursor: new_cursor}), nil}

      @arrow_right ->
        max_pos = String.length(prompt.text)
        new_cursor = min(max_pos, prompt.cursor + 1)
        {update_prompt(state, &%{&1 | cursor: new_cursor}), nil}

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
    prompt = current_prompt(state)
    {prompt.label, prompt.text, prompt.cursor}
  end

  @doc """
  Applies `fun` to the current PromptState inside the modal and writes
  back via `MingaEditor.Shell.Traditional.ModalWorkflow.transition`, keeping the modal sum type and
  consistency check in sync.
  """
  @spec update_prompt(state(), (PromptState.t() -> PromptState.t())) :: state()
  def update_prompt(state, fun) do
    {:prompt, payload} = state.shell_runtime.state.modal
    new_pui = fun.(payload.prompt_ui)

    MingaEditor.Shell.Traditional.ModalWorkflow.transition(
      state,
      {:prompt, PromptPayload.put_prompt_ui(payload, new_pui)}
    )
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec current_prompt(state()) :: PromptState.t()
  defp current_prompt(state) do
    case state.shell_runtime.state.modal do
      {:prompt, %{prompt_ui: prompt}} -> prompt
      _ -> %PromptState{}
    end
  end

  @spec do_tab(state(), PromptState.t()) :: state()
  defp do_tab(state, prompt) do
    handler = prompt.handler

    if function_exported?(handler, :on_tab, 1) do
      new_text = handler.on_tab(prompt.text)

      if new_text == prompt.text do
        state
      else
        new_cursor = String.length(new_text)
        update_prompt(state, &%{&1 | text: new_text, cursor: new_cursor})
      end
    else
      state
    end
  end

  @spec do_backspace(state(), PromptState.t()) :: state()
  defp do_backspace(state, %{cursor: 0} = _prompt), do: state

  defp do_backspace(state, prompt) do
    graphemes = String.graphemes(prompt.text)
    {before, after_} = Enum.split(graphemes, prompt.cursor)
    new_text = Enum.join(Enum.drop(before, -1)) <> Enum.join(after_)
    new_cursor = prompt.cursor - 1
    update_prompt(state, &%{&1 | text: new_text, cursor: new_cursor})
  end

  @spec do_delete(state(), PromptState.t()) :: state()
  defp do_delete(state, prompt) do
    graphemes = String.graphemes(prompt.text)
    do_delete_grapheme(state, prompt, graphemes)
  end

  @spec do_delete_grapheme(state(), PromptState.t(), [String.t()]) :: state()
  defp do_delete_grapheme(state, %{cursor: cursor}, graphemes) do
    if cursor >= Enum.count(graphemes) do
      state
    else
      {before, [_deleted | after_]} = Enum.split(graphemes, cursor)
      new_text = Enum.join(before) <> Enum.join(after_)
      update_prompt(state, &%{&1 | text: new_text})
    end
  end

  @spec do_insert(state(), PromptState.t(), non_neg_integer()) :: state()
  defp do_insert(state, prompt, key)
       when key >= 32 and key <= 0x10FFFF and not (key >= 0xD800 and key <= 0xDFFF) do
    char = <<key::utf8>>
    graphemes = String.graphemes(prompt.text)
    {before, after_} = Enum.split(graphemes, prompt.cursor)
    new_text = Enum.join(before) <> char <> Enum.join(after_)
    new_cursor = prompt.cursor + 1
    update_prompt(state, &%{&1 | text: new_text, cursor: new_cursor})
  end

  defp do_insert(state, _prompt, _key), do: state
end

defmodule MingaEditor.PromptUI do
  @moduledoc """
  Prompt UI: open, key handling, and close.

  Manages a single-line text input prompt in the minibuffer area. Extensions
  use this for collecting free-form text input (capture titles, rename targets,
  search queries). `MingaEditor.State.Prompt` owns text and cursor edits.

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
  alias MingaEditor.Shell.Traditional.ModalWorkflow

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
  - `:sensitive` — mask presentation and exclude input from key history (default: `false`)
  """
  @spec open(state(), module(), keyword()) :: state()
  def open(state, handler_module, opts \\ []) do
    default_text = Keyword.get(opts, :default, "")
    context = Keyword.get(opts, :context)
    label = Keyword.get(opts, :label, handler_module.label())
    sensitive = Keyword.get(opts, :sensitive, false)

    unless is_boolean(sensitive), do: raise(ArgumentError, ":sensitive must be a boolean")

    prompt_state = %PromptState{
      handler: handler_module,
      generation: Integer.mod(System.unique_integer([:positive, :monotonic]), 4_294_967_295) + 1,
      text: default_text,
      cursor: String.length(default_text),
      label: label,
      context: context,
      sensitive: sensitive
    }

    ModalWorkflow.open(state, {:prompt, PromptPayload.new(prompt_state)})
  end

  @doc """
  Closes the prompt without calling any handler callback.
  """
  @spec close(state()) :: state()
  def close(state), do: ModalWorkflow.dismiss(state)

  @doc """
  Returns true if a prompt is currently open.
  """
  @spec open?(state()) :: boolean()
  def open?(state), do: ModalOverlay.match(state.shell_runtime.state.modal, :prompt)

  @doc "Returns whether the current input belongs to a sensitive prompt."
  @spec sensitive_input?(state()) :: boolean()
  def sensitive_input?(%{
        shell_runtime: %{state: %{modal: {:prompt, %{prompt_ui: %PromptState{} = prompt}}}}
      }),
      do: PromptState.sensitive?(prompt)

  def sensitive_input?(_state), do: false

  @doc "Invokes the existing submit or cancel operation for the exact offered prompt."
  @spec activate(state(), non_neg_integer(), binary()) :: state()
  def activate(state, generation, item_id) do
    prompt = current_prompt(state)

    case PromptState.resolve_activation(prompt, generation, item_id) do
      {:ok, :submit} -> do_submit(state, prompt)
      {:ok, :cancel} -> do_cancel(state, prompt)
      {:error, _reason} -> state
    end
  end

  @doc """
  Handles a key event while the prompt is active.

  Returns `{state, action}` where action is always nil (prompts don't
  produce deferred actions like the picker does).
  """
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: {state(), action()}
  def handle_key(state, key, _mods) do
    {:prompt, %{prompt_ui: prompt}} = state.shell_runtime.state.modal

    next_state =
      case key do
        @escape ->
          do_cancel(state, prompt)

        @enter ->
          do_submit(state, prompt)

        @tab ->
          do_tab(state, prompt)

        @backspace ->
          install_changed_prompt(state, prompt, PromptState.backspace(prompt))

        @delete ->
          install_changed_prompt(state, prompt, PromptState.delete_forward(prompt))

        @arrow_left ->
          install_prompt(state, PromptState.move_left(prompt))

        @arrow_right ->
          install_prompt(state, PromptState.move_right(prompt))

        _ ->
          do_insert(state, prompt, key)
      end

    {next_state, nil}
  end

  @doc """
  Returns the label and current text for rendering.

  Returns `{label, text, cursor_col}` where cursor_col is the column
  within the text (not including the label width).
  """
  @spec render_data(state()) :: {String.t(), String.t(), non_neg_integer()}
  def render_data(state), do: state |> current_prompt() |> PromptState.render_data()

  @doc "Inserts decoded paste text at the prompt cursor."
  @spec insert_text(state(), String.t()) :: state()
  def insert_text(state, ""), do: state

  def insert_text(state, text) do
    prompt = current_prompt(state)
    install_prompt(state, PromptState.insert_text(prompt, text))
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec current_prompt(state()) :: PromptState.t()
  defp current_prompt(state) do
    case state.shell_runtime.state.modal do
      {:prompt, %{prompt_ui: prompt}} -> prompt
      _ -> %PromptState{}
    end
  end

  @spec install_changed_prompt(state(), PromptState.t(), PromptState.t()) :: state()
  defp install_changed_prompt(state, prompt, prompt), do: state

  defp install_changed_prompt(state, _prompt, next_prompt), do: install_prompt(state, next_prompt)

  @spec install_prompt(state(), PromptState.t()) :: state()
  defp install_prompt(state, prompt) do
    {:prompt, payload} = state.shell_runtime.state.modal
    ModalWorkflow.transition(state, {:prompt, PromptPayload.put_prompt_ui(payload, prompt)})
  end

  @spec do_submit(state(), PromptState.t()) :: state()
  defp do_submit(state, %{text: text, handler: handler, context: context}) do
    state = ModalWorkflow.close(state)

    if function_exported?(handler, :on_submit, 3),
      do: handler.on_submit(text, state, context),
      else: handler.on_submit(text, state)
  end

  @spec do_cancel(state(), PromptState.t()) :: state()
  defp do_cancel(state, %{handler: handler, context: context}) do
    state = ModalWorkflow.dismiss(state)

    cond do
      function_exported?(handler, :on_cancel, 2) -> handler.on_cancel(state, context)
      function_exported?(handler, :on_cancel, 1) -> handler.on_cancel(state)
      true -> state
    end
  end

  @spec do_tab(state(), PromptState.t()) :: state()
  defp do_tab(state, prompt) do
    handler = prompt.handler

    if function_exported?(handler, :on_tab, 1) do
      next_prompt = PromptState.replace_text(prompt, handler.on_tab(prompt.text))
      install_changed_prompt(state, prompt, next_prompt)
    else
      state
    end
  end

  @spec do_insert(state(), PromptState.t(), non_neg_integer()) :: state()
  defp do_insert(state, prompt, key)
       when key >= 32 and key <= 0x10FFFF and not (key >= 0xD800 and key <= 0xDFFF) do
    install_prompt(state, PromptState.insert_text(prompt, <<key::utf8>>))
  end

  defp do_insert(state, _prompt, _key), do: state
end

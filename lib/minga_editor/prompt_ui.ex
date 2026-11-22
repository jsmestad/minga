defmodule MingaEditor.PromptUI do
  @moduledoc """
  Prompt UI: open, key handling, and close.

  Manages text and confirmation prompts in the minibuffer area.
  `MingaEditor.State.Prompt` owns text and cursor edits.

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

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias MingaEditor.Extension.Prompt
  alias MingaEditor.MinibufferData
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
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
  - `:sensitive` — mask presentation and exclude input from key history (default: `false`)
  """
  @spec open(state(), module(), keyword()) :: state()
  def open(state, handler_module, opts \\ []) do
    label = Keyword.get(opts, :label, handler_module.label())
    sensitive = Keyword.get(opts, :sensitive, false)

    unless is_boolean(sensitive), do: raise(ArgumentError, ":sensitive must be a boolean")

    prompt_state = PromptState.new(:text, handler_module, label, opts)

    ModalWorkflow.open(state, {:prompt, PromptPayload.new(prompt_state)})
  end

  @doc false
  @spec open_extension(
          state(),
          CallbackInvoker.source(),
          PromptState.kind(),
          module(),
          term(),
          keyword()
        ) :: Prompt.result()
  def open_extension(state, source, kind, handler, args, opts) do
    with :ok <- admit_modal(state, Keyword.fetch!(opts, :admission)),
         :ok <- admit_handler(source, kind, handler) do
      prompt =
        PromptState.new(kind, handler, Keyword.fetch!(opts, :label),
          context: args,
          default: Keyword.get(opts, :default, "")
        )

      payload = PromptPayload.new(prompt, owner: source)
      {:ok, ModalWorkflow.open(state, {:prompt, payload})}
    end
  end

  @doc "Dismisses only the named source's prompt, without invoking its callbacks."
  @spec remove_source(state(), Minga.Extension.ContributionCleanup.contribution_source()) ::
          state()
  def remove_source(
        %{shell_runtime: %{state: %{modal: {:prompt, %{owner: {:extension, _name} = source}}}}} =
          state,
        source
      ),
      do: ModalWorkflow.dismiss(state)

  def remove_source(state, _source), do: state

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

  @doc "Invokes an action from the exact prompt opening that offered it."
  @spec activate(state(), non_neg_integer(), binary()) :: state()
  def activate(
        %{shell_runtime: %{state: %{modal: {:prompt, payload}}}} = state,
        generation,
        item_id
      ) do
    case PromptState.resolve_activation(payload.prompt_ui, generation, item_id) do
      {:ok, :submit} -> do_submit(state, payload)
      {:ok, :cancel} -> do_cancel(state, payload)
      {:error, _reason} -> state
    end
  end

  def activate(state, _generation, _item_id), do: state

  @doc """
  Handles a key event while the prompt is active.

  Returns `{state, action}` where action is always nil (prompts don't
  produce deferred actions like the picker does).
  """
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: {state(), action()}
  def handle_key(state, key, _mods) do
    {:prompt, payload} = state.shell_runtime.state.modal
    {handle_prompt_key(state, payload, key), nil}
  end

  @spec handle_prompt_key(state(), PromptPayload.t(), non_neg_integer()) :: state()
  defp handle_prompt_key(state, %PromptPayload{prompt_ui: %{kind: :confirm}} = payload, key) do
    case key do
      yes when yes in [?y, ?Y] -> do_submit(state, payload)
      no when no in [?n, ?N, @escape] -> do_cancel(state, payload)
      _ -> state
    end
  end

  defp handle_prompt_key(state, %PromptPayload{prompt_ui: prompt} = payload, key) do
    case key do
      @escape ->
        do_cancel(state, payload)

      @enter ->
        do_submit(state, payload)

      @tab ->
        do_tab(state, payload)

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
    install_changed_prompt(state, prompt, PromptState.insert_text(prompt, text))
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec admit_modal(state(), Prompt.admission()) ::
          :ok | {:error, :modal_busy | :unsupported_shell}
  defp admit_modal(%EditorState{session: %{pending_quit: kind}}, _admission)
       when kind in [:quit, :quit_all],
       do: {:error, :modal_busy}

  defp admit_modal(
         %EditorState{
           shell_runtime: %Runtime{state: %ShellState{modal: modal}},
           workspace: %{editing: %{mode: mode}}
         } = state,
         admission
       ) do
    cond do
      ModalOverlay.match(modal, :conflict) ->
        {:error, :modal_busy}

      admission == :if_idle and
          (ModalOverlay.active?(modal) or mode == :tool_confirm or
             MinibufferData.visible?(state)) ->
        {:error, :modal_busy}

      true ->
        :ok
    end
  end

  defp admit_modal(%EditorState{}, _admission), do: {:error, :unsupported_shell}

  @spec admit_handler(CallbackInvoker.source(), PromptState.kind(), module()) ::
          :ok | {:error, :source_unavailable | :invalid_handler}
  defp admit_handler(source, kind, handler) do
    case CodeLease.admit_callback(source, handler, :prompt_open) do
      {:ok, lease} ->
        try do
          callback = if kind == :text, do: :on_submit, else: :on_confirm

          if Code.ensure_loaded?(handler) and function_exported?(handler, callback, 3),
            do: :ok,
            else: {:error, :invalid_handler}
        after
          CodeLease.release(lease)
        end

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

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

  @spec do_submit(state(), PromptPayload.t()) :: state()
  defp do_submit(state, %PromptPayload{
         owner: {:extension, _name} = source,
         prompt_ui: %PromptState{kind: :confirm, context: args, handler: handler}
       }) do
    state |> ModalWorkflow.dismiss() |> invoke(source, handler, :on_confirm, [:accepted, args])
  end

  defp do_submit(state, %PromptPayload{
         owner: {:extension, _name} = source,
         prompt_ui: %PromptState{text: text, context: args, handler: handler}
       }) do
    state |> ModalWorkflow.dismiss() |> invoke(source, handler, :on_submit, [text, args])
  end

  defp do_submit(state, %PromptPayload{
         prompt_ui: %{text: text, handler: handler, context: context}
       }) do
    state = ModalWorkflow.close(state)

    if function_exported?(handler, :on_submit, 3),
      do: handler.on_submit(text, state, context),
      else: handler.on_submit(text, state)
  end

  @spec do_cancel(state(), PromptPayload.t()) :: state()
  defp do_cancel(state, %PromptPayload{
         owner: {:extension, _name} = source,
         prompt_ui: %PromptState{kind: :confirm, context: args, handler: handler}
       }) do
    state |> ModalWorkflow.dismiss() |> invoke(source, handler, :on_confirm, [:canceled, args])
  end

  defp do_cancel(state, %PromptPayload{
         owner: {:extension, _name} = source,
         prompt_ui: %PromptState{context: args, handler: handler}
       }) do
    state = ModalWorkflow.dismiss(state)

    if function_exported?(handler, :on_cancel, 2),
      do: invoke(state, source, handler, :on_cancel, [args]),
      else: state
  end

  defp do_cancel(state, %PromptPayload{prompt_ui: %{handler: handler, context: context}}) do
    state = ModalWorkflow.dismiss(state)

    cond do
      function_exported?(handler, :on_cancel, 2) -> handler.on_cancel(state, context)
      function_exported?(handler, :on_cancel, 1) -> handler.on_cancel(state)
      true -> state
    end
  end

  @spec invoke(state(), CallbackInvoker.source(), module(), atom(), [term()]) :: state()
  defp invoke(state, source, handler, function, args) do
    case CallbackInvoker.invoke(source, handler, function, [state | args], :prompt_callback) do
      {:ok, %EditorState{} = updated} ->
        updated

      {:ok, returned} ->
        _failure = CallbackInvoker.invalid_return(source, handler, function, returned)
        state

      {:error, _failure} ->
        state
    end
  end

  @spec do_tab(state(), PromptPayload.t()) :: state()
  defp do_tab(state, %PromptPayload{owner: :global, prompt_ui: %{handler: handler} = prompt}) do
    if function_exported?(handler, :on_tab, 1) do
      next_prompt = PromptState.replace_text(prompt, handler.on_tab(prompt.text))
      install_changed_prompt(state, prompt, next_prompt)
    else
      state
    end
  end

  defp do_tab(state, _payload), do: state

  @spec do_insert(state(), PromptState.t(), non_neg_integer()) :: state()
  defp do_insert(state, prompt, key)
       when key >= 32 and key <= 0x10FFFF and not (key >= 0xD800 and key <= 0xDFFF) do
    install_prompt(state, PromptState.insert_text(prompt, <<key::utf8>>))
  end

  defp do_insert(state, _prompt, _key), do: state
end

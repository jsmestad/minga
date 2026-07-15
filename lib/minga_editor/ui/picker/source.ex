defmodule MingaEditor.UI.Picker.Source do
  @moduledoc """
  Behaviour for picker sources.

  A source provides candidates for a picker and handles the select/cancel
  actions. Implementing this behaviour is all that's needed to add a new
  picker-powered feature — no changes to the editor core required.

  ## Callbacks

  - `candidates/1` — returns the list of picker items given some context
  - `on_select/2` — called when the user selects an item; returns new editor state
  - `on_bulk_select/2` — optionally called when the user confirms explicitly marked items
  - `on_cancel/1` — called when the user cancels; returns new editor state
  - `preview?/0` — legacy live-navigation preview flag (default: false)
  - `live_preview?/0` — whether navigating the picker should temporarily run `on_select/2` for the highlighted item (default: `preview?/0` for backwards compatibility)
  - `gui_preview?/0` — whether the GUI preview pane should be shown for this source (default: false)
  - `preview/2` — optional source-provided GUI preview content for the selected item, called with the render context
  - `title/0` — the picker title shown in the separator bar

  ## Example

      defmodule MySource do
        @behaviour MingaEditor.UI.Picker.Source

        @impl true
        def title, do: "My picker"

        @impl true
        def candidates(_context),
          do: [%MingaEditor.UI.Picker.Item{id: :a, label: "item a", description: "description"}]

        @impl true
        def on_select(item, state), do: state

        @impl true
        def on_cancel(state), do: state
      end
  """

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.InvocationContext
  alias MingaEditor.Frontend.Emit.Context, as: EmitContext
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context

  @doc "Returns the display title for this picker source."
  @callback title() :: String.t()

  @doc "Returns the list of candidates to display in the picker."
  @callback candidates(Context.t()) :: [Picker.item()]

  @doc """
  Called when the user selects an item. Returns the new editor state.

  Important: this callback runs *after* the picker has been closed
  (`state.shell_runtime.state.modal` has been reset to `:none`). Any context the
  callback needs must travel with the `Picker.item()` (typically embedded
  in `Item.id`). Reading `state.shell_runtime.state.modal` here will see `:none`.
  """
  @callback on_select(Picker.item(), MingaEditor.State.t()) :: MingaEditor.State.t()

  @doc """
  Called when the user confirms explicitly marked items. Returns the new editor state.

  Sources that do not implement this callback ignore picker marks and keep the
  single-selection behavior from `on_select/2`.
  """
  @callback on_bulk_select([Picker.item()], MingaEditor.State.t()) :: MingaEditor.State.t()

  @doc "Called when the user cancels the picker. Returns the new editor state."
  @callback on_cancel(MingaEditor.State.t()) :: MingaEditor.State.t()

  @doc "Legacy live-navigation preview flag."
  @callback preview?() :: boolean()

  @doc "Whether navigating the picker should live-preview the selection."
  @callback live_preview?() :: boolean()

  @doc "Whether the GUI preview pane should be shown for this source."
  @callback gui_preview?() :: boolean()

  @typedoc "A styled preview segment: display text, 24-bit foreground color, bold flag."
  @type preview_segment :: {String.t(), non_neg_integer(), boolean()}

  @typedoc "Render context passed to `preview/2` from the GUI emit pipeline."
  @type preview_context :: EmitContext.t()

  @doc "Returns source-provided GUI preview content for an item."
  @callback preview(Picker.item(), context :: preview_context()) :: [[preview_segment()]] | nil

  @typedoc "An alternative action: display name and action identifier."
  @type action_entry :: {name :: String.t(), action_id :: term()}

  @doc """
  Returns the list of alternative actions available for a picker item.
  The first entry is conventionally the default action.
  """
  @callback actions(Picker.item()) :: [action_entry()]

  @doc """
  Executes an alternative action on a picker item.
  Called when the user selects an action from the C-o menu.

  Like `on_select/2`, this runs *after* the picker has been closed. Any
  context required must travel with the `Picker.item()`; do not read
  `state.shell_runtime.state.modal` here.
  """
  @callback on_action(term(), Picker.item(), MingaEditor.State.t()) :: MingaEditor.State.t()

  @doc "Returns the list of alternative actions available for a marked item batch."
  @callback bulk_actions([Picker.item()]) :: [action_entry()]

  @doc "Executes an alternative action on a marked item batch."
  @callback on_bulk_action(term(), [Picker.item()], MingaEditor.State.t()) ::
              MingaEditor.State.t()

  @typedoc "Picker layout: bottom-anchored (default) or centered floating window."
  @type layout :: :bottom | :centered

  @doc """
  Returns the preferred layout for this picker source.
  Defaults to `:bottom` (Emacs-style minibuffer overlay).
  `:centered` renders inside a FloatingWindow overlay.
  """
  @callback layout() :: layout()

  @doc """
  Whether the picker should stay open after selecting an item.
  Defaults to `false` (picker closes on Enter). When `true`, the picker
  calls `on_select`, then refreshes items via `candidates/1` so the
  user can see updated state (e.g., tool install status changes).
  """
  @callback keep_open_on_select?() :: boolean()

  @doc """
  Whether this source fetches candidates asynchronously.
  When `true`, `PickerUI.open/3` opens the picker immediately with a
  "Searching..." indicator and fetches candidates in a background task.
  Defaults to `false` (synchronous).
  """
  @callback async?() :: boolean()

  @typedoc """
  Extra info an async source can report alongside its candidates, surfaced by the
  editor once results land (e.g. a "results truncated" status line). Sources that
  don't need it omit `async_fetch/1` and the editor uses an empty map.
  """
  @type fetch_meta :: %{optional(:status) => String.t()}

  @doc """
  Async candidate fetch with optional reporting metadata.

  Runs off the editor input path inside the picker's background task. Sources that
  need to report a status (e.g. project search reporting that results were capped)
  implement this and return `{:ok, items, meta}`; everything else falls back to
  `candidates/1` via `fetch/2`. Errors are returned as `{:error, message}`.
  """
  @callback async_fetch(Context.t()) ::
              {:ok, [Picker.item()], fetch_meta()} | {:error, String.t()}

  @doc """
  Enriches a bounded list of items for display.

  Filtering keeps only the top results, so a source with expensive per-item
  display work (icons, colors, two-line descriptions, status annotations) can
  return lean items from `candidates/1` and defer that work to this callback,
  which runs only on the small set actually shown. The default is identity, so
  sources that already return fully-built items need not implement it.

  Enrichment must be a pure function of the items themselves (any state a source
  needs should be stashed in `Item.meta` at `candidates/1` time), because it runs
  on every render of the visible window.
  """
  @callback enrich([Picker.item()]) :: [Picker.item()]

  @optional_callbacks [
    preview?: 0,
    live_preview?: 0,
    gui_preview?: 0,
    preview: 2,
    actions: 1,
    on_action: 3,
    on_bulk_select: 2,
    bulk_actions: 1,
    on_bulk_action: 3,
    layout: 0,
    keep_open_on_select?: 0,
    async?: 0,
    async_fetch: 1,
    enrich: 1
  ]

  @doc """
  Default `on_cancel` implementation: restores the buffer that was active
  when the picker opened (stored in the picker payload's `restore` field),
  or returns state unchanged if no restore index was saved.
  """
  @spec restore_or_keep(MingaEditor.State.t()) :: MingaEditor.State.t()
  def restore_or_keep(%MingaEditor.State{} = state) do
    case state.shell_runtime.state.modal do
      {:picker, %{picker_ui: %{restore: idx}}} when is_integer(idx) ->
        MingaEditor.BufferActivation.activate(state, idx)

      _ ->
        state
    end
  end

  @doc "Returns the authoritative contribution source installed at callback invocation."
  @spec source_identity(module()) :: ContributionCleanup.contribution_source() | nil
  def source_identity(_module) do
    case InvocationContext.current_source() do
      {:ok, source} -> source
      :none -> nil
    end
  end

  @doc "Returns a validated picker title."
  @spec title(module(), ContributionCleanup.contribution_source() | nil) :: String.t()
  def title(module, source \\ nil) do
    invoke_value(module, :title, [], source, &is_binary/1, "")
  end

  @doc "Returns a validated picker candidate collection."
  @spec candidates(module(), Context.t(), ContributionCleanup.contribution_source() | nil) ::
          [Picker.item()]
  def candidates(module, context, source \\ nil) do
    invoke_value(module, :candidates, [context], source, &is_list/1, [])
  end

  @doc "Runs a validated picker selection callback."
  @spec on_select(
          module(),
          Picker.item(),
          MingaEditor.State.t(),
          ContributionCleanup.contribution_source() | nil
        ) ::
          MingaEditor.State.t()
  def on_select(module, item, state, source \\ nil) do
    invoke_state(module, :on_select, [item, state], source, state)
  end

  @doc "Runs a validated picker cancellation callback."
  @spec on_cancel(
          module(),
          MingaEditor.State.t(),
          ContributionCleanup.contribution_source() | nil
        ) ::
          MingaEditor.State.t()
  def on_cancel(module, state, source \\ nil) do
    invoke_state(module, :on_cancel, [state], source, state)
  end

  @doc "Returns whether a source module should live-preview the highlighted item."
  @spec preview?(module(), ContributionCleanup.contribution_source() | nil) :: boolean()
  def preview?(module, source \\ nil) do
    if exported?(module, :preview?, 0) do
      invoke_value(module, :preview?, [], source, &is_boolean/1, false)
    else
      false
    end
  end

  @doc "Returns source-provided preview content, or nil when no preview callback exists."
  @spec preview(
          module(),
          Picker.item(),
          preview_context(),
          ContributionCleanup.contribution_source() | nil
        ) :: [[preview_segment()]] | nil
  def preview(module, item, context, source \\ nil) do
    if exported?(module, :preview, 2) do
      invoke_value(module, :preview, [item, context], source, &valid_preview?/1, nil)
    else
      nil
    end
  end

  @doc "Returns whether navigating the picker should live-preview the selection."
  @spec live_preview?(module(), ContributionCleanup.contribution_source() | nil) :: boolean()
  def live_preview?(module, source \\ nil) do
    if exported?(module, :live_preview?, 0) do
      invoke_value(module, :live_preview?, [], source, &is_boolean/1, false)
    else
      preview?(module, source)
    end
  end

  @doc "Whether the GUI preview pane should be shown for the source."
  @spec gui_preview?(module(), ContributionCleanup.contribution_source() | nil) :: boolean()
  def gui_preview?(module, source \\ nil) do
    if exported?(module, :gui_preview?, 0) do
      invoke_value(module, :gui_preview?, [], source, &is_boolean/1, false)
    else
      false
    end
  end

  @doc "Returns whether a source module supports alternative actions."
  @spec has_actions?(module()) :: boolean()
  def has_actions?(module) do
    exported?(module, :actions, 1) and exported?(module, :on_action, 3)
  end

  @doc "Returns a validated action collection, or an empty list when unsupported."
  @spec actions(module(), Picker.item(), ContributionCleanup.contribution_source() | nil) ::
          [action_entry()]
  def actions(module, item, source \\ nil) do
    if has_actions?(module) do
      invoke_value(module, :actions, [item], source, &is_list/1, [])
    else
      []
    end
  end

  @doc "Runs a validated alternative action."
  @spec on_action(
          module(),
          term(),
          Picker.item(),
          MingaEditor.State.t(),
          ContributionCleanup.contribution_source() | nil
        ) :: MingaEditor.State.t()
  def on_action(module, action, item, state, source \\ nil) do
    invoke_state(module, :on_action, [action, item, state], source, state)
  end

  @doc "Returns whether a source module supports bulk select."
  @spec has_bulk_select?(module()) :: boolean()
  def has_bulk_select?(module), do: exported?(module, :on_bulk_select, 2)

  @doc "Runs bulk select, returning state unchanged when unsupported."
  @spec bulk_select(
          module(),
          [Picker.item()],
          MingaEditor.State.t(),
          ContributionCleanup.contribution_source() | nil
        ) :: MingaEditor.State.t()
  def bulk_select(module, items, state, source \\ nil) do
    if has_bulk_select?(module) do
      invoke_state(module, :on_bulk_select, [items, state], source, state)
    else
      state
    end
  end

  @doc "Returns whether a source module supports bulk alternative actions."
  @spec has_bulk_actions?(module()) :: boolean()
  def has_bulk_actions?(module) do
    exported?(module, :bulk_actions, 1) and exported?(module, :on_bulk_action, 3)
  end

  @doc "Returns validated bulk actions, or an empty list when unsupported."
  @spec bulk_actions(
          module(),
          [Picker.item()],
          ContributionCleanup.contribution_source() | nil
        ) :: [action_entry()]
  def bulk_actions(module, items, source \\ nil) do
    if has_bulk_actions?(module) do
      invoke_value(module, :bulk_actions, [items], source, &is_list/1, [])
    else
      []
    end
  end

  @doc "Runs a validated bulk action, returning state unchanged when unsupported."
  @spec on_bulk_action(
          module(),
          term(),
          [Picker.item()],
          MingaEditor.State.t(),
          ContributionCleanup.contribution_source() | nil
        ) :: MingaEditor.State.t()
  def on_bulk_action(module, action, items, state, source \\ nil) do
    if has_bulk_actions?(module) do
      invoke_state(module, :on_bulk_action, [action, items, state], source, state)
    else
      state
    end
  end

  @doc "Returns the validated preferred picker layout."
  @spec layout(module(), ContributionCleanup.contribution_source() | nil) :: layout()
  def layout(module, source \\ nil) do
    if exported?(module, :layout, 0) do
      invoke_value(module, :layout, [], source, &(&1 in [:bottom, :centered]), :bottom)
    else
      :bottom
    end
  end

  @doc "Returns whether the picker should stay open after selection."
  @spec keep_open_on_select?(module(), ContributionCleanup.contribution_source() | nil) ::
          boolean()
  def keep_open_on_select?(module, source \\ nil) do
    if exported?(module, :keep_open_on_select?, 0) do
      invoke_value(module, :keep_open_on_select?, [], source, &is_boolean/1, false)
    else
      false
    end
  end

  @doc "Returns whether a source fetches candidates asynchronously."
  @spec async?(module(), ContributionCleanup.contribution_source() | nil) :: boolean()
  def async?(module, source \\ nil) do
    if exported?(module, :async?, 0) do
      invoke_value(module, :async?, [], source, &is_boolean/1, false)
    else
      false
    end
  end

  @doc "Runs and validates an asynchronous candidate fetch."
  @spec fetch(module(), Context.t(), ContributionCleanup.contribution_source() | nil) ::
          {:ok, [Picker.item()], fetch_meta()} | {:error, String.t()}
  def fetch(module, context, source \\ nil) do
    if exported?(module, :async_fetch, 1) do
      invoke_value(
        module,
        :async_fetch,
        [context],
        source,
        &valid_fetch_result?/1,
        {:error, "Extension picker fetch failed"}
      )
    else
      case candidates(module, context, source) do
        items when is_list(items) -> {:ok, items, %{}}
      end
    end
  end

  @doc "Returns whether a source defers display enrichment."
  @spec enriches?(module()) :: boolean()
  def enriches?(module), do: exported?(module, :enrich, 1)

  @doc "Returns a validated enriched candidate collection."
  @spec enrich(
          module(),
          [Picker.item()],
          ContributionCleanup.contribution_source() | nil
        ) :: [Picker.item()]
  def enrich(module, items, source \\ nil) do
    if enriches?(module) do
      invoke_value(module, :enrich, [items], source, &is_list/1, items)
    else
      items
    end
  end

  @spec invoke_state(
          module(),
          atom(),
          [term()],
          ContributionCleanup.contribution_source() | nil,
          MingaEditor.State.t()
        ) :: MingaEditor.State.t()
  defp invoke_state(module, function, args, {:extension, _name} = source, original_state) do
    case CallbackInvoker.invoke(source, module, function, args, :picker_callback) do
      {:ok, %MingaEditor.State{} = state} ->
        state

      {:ok, returned} ->
        invalid_extension_value(source, module, function, returned, original_state)

      {:error, _failure} ->
        original_state
    end
  end

  defp invoke_state(module, function, args, _source, _original_state) do
    case apply(module, function, args) do
      %MingaEditor.State{} = state -> state
      returned -> raise ArgumentError, invalid_core_return(module, function, returned)
    end
  end

  @spec invoke_value(
          module(),
          atom(),
          [term()],
          ContributionCleanup.contribution_source() | nil,
          (term() -> boolean()),
          result
        ) :: result
        when result: var
  defp invoke_value(module, function, args, {:extension, _name} = source, validator, fallback) do
    case CallbackInvoker.invoke(source, module, function, args, :picker_callback) do
      {:ok, returned} ->
        validate_extension_value(source, module, function, returned, validator, fallback)

      {:error, _failure} ->
        fallback
    end
  end

  defp invoke_value(module, function, args, _source, validator, _fallback) do
    returned = apply(module, function, args)

    if validator.(returned) do
      returned
    else
      raise ArgumentError, invalid_core_return(module, function, returned)
    end
  end

  @spec validate_extension_value(
          CallbackInvoker.source(),
          module(),
          atom(),
          term(),
          (term() -> boolean()),
          result
        ) :: result
        when result: var
  defp validate_extension_value(source, module, function, returned, validator, fallback) do
    if validator.(returned) do
      returned
    else
      invalid_extension_value(source, module, function, returned, fallback)
    end
  end

  @spec invalid_extension_value(CallbackInvoker.source(), module(), atom(), term(), result) ::
          result
        when result: var
  defp invalid_extension_value(source, module, function, returned, fallback) do
    _failure = CallbackInvoker.invalid_return(source, module, function, returned)
    fallback
  end

  @spec invalid_core_return(module(), atom(), term()) :: String.t()
  defp invalid_core_return(module, function, returned) do
    "core picker callback #{inspect(module)}.#{function} returned invalid value: #{inspect(returned, limit: 20)}"
  end

  @spec valid_preview?(term()) :: boolean()
  defp valid_preview?(nil), do: true
  defp valid_preview?(lines) when is_list(lines), do: Enum.all?(lines, &valid_preview_line?/1)
  defp valid_preview?(_returned), do: false

  @spec valid_preview_line?(term()) :: boolean()
  defp valid_preview_line?(line) when is_list(line),
    do: Enum.all?(line, &valid_preview_segment?/1)

  defp valid_preview_line?(_line), do: false

  @spec valid_preview_segment?(term()) :: boolean()
  defp valid_preview_segment?({text, color, bold?}),
    do: is_binary(text) and is_integer(color) and is_boolean(bold?)

  defp valid_preview_segment?(_segment), do: false

  @spec valid_fetch_result?(term()) :: boolean()
  defp valid_fetch_result?({:ok, items, meta}) when is_list(items) and is_map(meta) do
    case Map.get(meta, :status) do
      nil -> true
      status -> is_binary(status)
    end
  end

  defp valid_fetch_result?({:error, message}), do: is_binary(message)
  defp valid_fetch_result?(_result), do: false

  @spec exported?(module(), atom(), non_neg_integer()) :: boolean()
  defp exported?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end

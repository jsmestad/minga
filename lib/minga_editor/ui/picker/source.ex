defmodule MingaEditor.UI.Picker.Source do
  @moduledoc """
  Behaviour for picker sources.

  A source provides candidates for a picker and handles the select/cancel
  actions. Implementing this behaviour is all that's needed to add a new
  picker-powered feature — no changes to the editor core required.

  ## Callbacks

  - `candidates/1` — returns the list of picker items given some context
  - `on_select/2` — called when the user selects an item; returns new editor state
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
        def candidates(_context), do: [{:a, "item a", "description"}]

        @impl true
        def on_select(item, state), do: state

        @impl true
        def on_cancel(state), do: state
      end
  """

  alias MingaEditor.Frontend.Emit.Context, as: EmitContext
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context

  @doc "Returns the display title for this picker source."
  @callback title() :: String.t()

  @doc "Returns the list of candidates to display in the picker."
  @callback candidates(Context.t()) :: [Picker.item()]

  @doc """
  Called when the user selects an item. Returns the new editor state.

  Important: this callback runs *after* the picker has been closed
  (`state.shell_state.modal` has been reset to `:none`). Any context the
  callback needs must travel with the `Picker.item()` (typically embedded
  in `Item.id`). Reading `state.shell_state.modal` here will see `:none`.
  """
  @callback on_select(Picker.item(), state :: term()) :: term()

  @doc "Called when the user cancels the picker. Returns the new editor state."
  @callback on_cancel(state :: term()) :: term()

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
  @type action_entry :: {name :: String.t(), action_id :: atom()}

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
  `state.shell_state.modal` here.
  """
  @callback on_action(atom(), Picker.item(), state :: term()) :: term()

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

  @optional_callbacks [
    preview?: 0,
    live_preview?: 0,
    gui_preview?: 0,
    preview: 2,
    actions: 1,
    on_action: 3,
    layout: 0,
    keep_open_on_select?: 0
  ]

  @doc """
  Default `on_cancel` implementation: restores the buffer that was active
  when the picker opened (stored in the picker payload's `restore` field),
  or returns state unchanged if no restore index was saved.
  """
  @spec restore_or_keep(term()) :: term()
  def restore_or_keep(state) do
    case state.shell_state.modal do
      {:picker, %{picker_ui: %{restore: idx}}} when is_integer(idx) ->
        EditorState.switch_buffer(state, idx)

      _ ->
        state
    end
  end

  @doc """
  Returns whether a source module should live-preview the highlighted item.
  Falls back to `false` if the callback is not implemented.
  """
  @spec preview?(module()) :: boolean()
  def preview?(module) do
    if exported?(module, :preview?, 0) do
      module.preview?()
    else
      false
    end
  end

  @doc """
  Returns source-provided preview content, or nil when no preview callback exists.
  """
  @spec preview(module(), Picker.item(), preview_context()) :: [[preview_segment()]] | nil
  def preview(module, item, context) do
    if exported?(module, :preview, 2) do
      module.preview(item, context)
    else
      nil
    end
  end

  @doc "Returns whether navigating the picker should live-preview the selection."
  @spec live_preview?(module()) :: boolean()
  def live_preview?(module) do
    if exported?(module, :live_preview?, 0) do
      module.live_preview?()
    else
      preview?(module)
    end
  end

  @doc "Whether the GUI preview pane should be shown for the source."
  @spec gui_preview?(module()) :: boolean()
  def gui_preview?(module) do
    if exported?(module, :gui_preview?, 0) do
      module.gui_preview?()
    else
      false
    end
  end

  @doc """
  Returns whether a source module supports alternative actions (C-o menu).
  """
  @spec has_actions?(module()) :: boolean()
  def has_actions?(module) do
    exported?(module, :actions, 1) and exported?(module, :on_action, 3)
  end

  @doc """
  Returns the actions for an item, or an empty list if the source doesn't support actions.
  """
  @spec actions(module(), Picker.item()) :: [action_entry()]
  def actions(module, item) do
    if has_actions?(module) do
      module.actions(item)
    else
      []
    end
  end

  @doc """
  Returns the preferred layout for a source, defaulting to `:bottom`.
  """
  @spec layout(module()) :: layout()
  def layout(module) do
    if exported?(module, :layout, 0) do
      module.layout()
    else
      :bottom
    end
  end

  @doc """
  Returns whether the picker should stay open after selecting an item.
  """
  @spec keep_open_on_select?(module()) :: boolean()
  def keep_open_on_select?(module) do
    if exported?(module, :keep_open_on_select?, 0) do
      module.keep_open_on_select?()
    else
      false
    end
  end

  @spec exported?(module(), atom(), non_neg_integer()) :: boolean()
  defp exported?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end

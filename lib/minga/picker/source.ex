defmodule Minga.Picker.Source do
  @moduledoc """
  Behaviour for picker sources.

  A source provides candidates for a picker and handles the select/cancel
  actions. Implementing this behaviour is all that's needed to add a new
  picker-powered feature — no changes to the editor core required.

  ## Callbacks

  - `candidates/1` — returns the list of picker items given some context
  - `on_select/2` — called when the user selects an item; returns new editor state
  - `on_cancel/1` — called when the user cancels; returns new editor state
  - `preview?/0` — whether navigating the picker should preview the selection (default: false)
  - `title/0` — the picker title shown in the separator bar

  ## Example

      defmodule MySource do
        @behaviour Minga.Picker.Source

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

  alias Minga.Editor.State, as: EditorState
  alias Minga.Picker

  @typedoc "Context passed to `candidates/1` — typically editor state or options."
  @type context :: term()

  @doc "Returns the display title for this picker source."
  @callback title() :: String.t()

  @doc "Returns the list of candidates to display in the picker."
  @callback candidates(context()) :: [Picker.item()]

  @doc "Called when the user selects an item. Returns the new editor state."
  @callback on_select(Picker.item(), state :: term()) :: term()

  @doc "Called when the user cancels the picker. Returns the new editor state."
  @callback on_cancel(state :: term()) :: term()

  @doc "Whether navigating the picker should live-preview the selection."
  @callback preview?() :: boolean()

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

  @optional_callbacks [preview?: 0, actions: 1, on_action: 3, layout: 0, keep_open_on_select?: 0]

  @doc """
  Default `on_cancel` implementation: restores the buffer that was active
  when the picker opened (stored in `picker_ui.restore`), or returns state
  unchanged if no restore index was saved.
  """
  @spec restore_or_keep(term()) :: term()
  def restore_or_keep(%{picker_ui: %{restore: idx}} = state) when is_integer(idx) do
    EditorState.switch_buffer(state, idx)
  end

  def restore_or_keep(state), do: state

  @doc """
  Returns whether a source module supports preview.
  Falls back to `false` if the callback is not implemented.
  """
  @spec preview?(module()) :: boolean()
  def preview?(module) do
    if function_exported?(module, :preview?, 0) do
      module.preview?()
    else
      false
    end
  end

  @doc """
  Returns whether a source module supports alternative actions (C-o menu).
  """
  @spec has_actions?(module()) :: boolean()
  def has_actions?(module) do
    function_exported?(module, :actions, 1) and function_exported?(module, :on_action, 3)
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
    if function_exported?(module, :layout, 0) do
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
    if function_exported?(module, :keep_open_on_select?, 0) do
      module.keep_open_on_select?()
    else
      false
    end
  end
end

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

  @optional_callbacks [preview?: 0]

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
end

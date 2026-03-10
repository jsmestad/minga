defmodule Minga.Command do
  @moduledoc """
  A named editor command.

  Commands are the bridge between key sequences (via the keymap trie)
  and editor state mutations. Each command has a name (for registry
  lookup), a human-readable description (for which-key display), and
  an execute function that maps editor state → new editor state.

  ## Scopeable commands

  Commands that toggle buffer-local options can declare a `scope`
  descriptor. When invoked from a keybinding, scopeable commands
  apply to the current buffer (fast path). When invoked from the
  command palette, the palette presents a scope picker ("This Buffer"
  / "All Buffers") so the user can choose where the change applies.

  The scope descriptor is a map with:

  * `:option` — the option name atom (e.g. `:wrap`)
  * `:toggle` — `true` for boolean toggle, or a function
    `(current_value -> new_value)` for non-boolean cycling

  ## Example

      %Minga.Command{
        name: :save,
        description: "Save the current file",
        execute: fn state -> Minga.Editor.Commands.execute(state, :save) end
      }

      # Scopeable toggle:
      %Minga.Command{
        name: :toggle_wrap,
        description: "Toggle word wrap",
        execute: fn state -> Minga.Editor.Commands.execute(state, :toggle_wrap) end,
        scope: %{option: :wrap, toggle: true}
      }
  """

  @enforce_keys [:name, :description, :execute]
  defstruct [:name, :description, :execute, :scope]

  @typedoc """
  Scope descriptor for commands that toggle buffer-local options.

  * `:option` — the option name atom
  * `:toggle` — `true` for boolean negation, or a `(term -> term)` function
  """
  @type scope :: %{option: atom(), toggle: true | (term() -> term())}

  @typedoc """
  An editor command struct.

  * `name`        — atom identifier used for registry lookup and keymap binding
  * `description` — human-readable label shown in which-key popups
  * `execute`     — function applied to the editor state, returns new state
  * `scope`       — optional scope descriptor for buffer-local option toggles
  """
  @type t :: %__MODULE__{
          name: atom(),
          description: String.t(),
          execute: function(),
          scope: scope() | nil
        }

  @doc "Returns true if this command is scopeable (toggles a buffer-local option)."
  @spec scopeable?(t()) :: boolean()
  def scopeable?(%__MODULE__{scope: nil}), do: false
  def scopeable?(%__MODULE__{scope: %{option: _, toggle: _}}), do: true

  @doc """
  Computes the new value for a scopeable command given the current value.

  For `toggle: true`, negates the boolean. For a function, calls it.
  """
  @spec compute_new_value(t(), term()) :: term()
  def compute_new_value(%__MODULE__{scope: %{toggle: true}}, current), do: !current

  def compute_new_value(%__MODULE__{scope: %{toggle: f}}, current) when is_function(f, 1),
    do: f.(current)
end

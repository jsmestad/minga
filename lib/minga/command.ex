defmodule Minga.Command do
  @moduledoc """
  A named editor command.

  Commands are the bridge between key sequences (via the keymap trie)
  and editor state mutations. Each command has a name (for registry
  lookup), a human-readable description (for which-key display), and
  an execute function that maps editor state → new editor state.

  ## Example

      %Minga.Command{
        name: :save,
        description: "Save the current file",
        execute: fn state -> Minga.Editor.save(state) end
      }
  """

  @enforce_keys [:name, :description, :execute]
  defstruct [:name, :description, :execute]

  @typedoc """
  An editor command struct.

  * `name`        — atom identifier used for registry lookup and keymap binding
  * `description` — human-readable label shown in which-key popups
  * `execute`     — function applied to the editor state, returns new state
  """
  @type t :: %__MODULE__{
          name: atom(),
          description: String.t(),
          execute: function()
        }
end

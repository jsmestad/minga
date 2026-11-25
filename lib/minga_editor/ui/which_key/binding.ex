defmodule MingaEditor.UI.WhichKey.Binding do
  @moduledoc "A formatted key binding entry for which-key popup display."

  @enforce_keys [:key, :description, :kind]
  defstruct [:key, :description, :kind, codepoint: 0, modifiers: 0, command: nil]

  @type kind :: :command | :group

  @typedoc "`key` is the formatted key; `codepoint` and `modifiers` are the raw key; `command` is what a command row runs."
  @type t :: %__MODULE__{
          key: String.t(),
          description: String.t(),
          kind: kind(),
          codepoint: non_neg_integer(),
          modifiers: non_neg_integer(),
          command: atom() | tuple() | nil
        }
end

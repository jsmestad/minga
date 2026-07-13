defmodule MingaEditor.UI.WhichKey.Binding do
  @moduledoc "A formatted key binding entry for which-key popup display."

  @enforce_keys [:key, :description, :kind]
  defstruct [:key, :description, :kind, :icon]

  @type kind :: :command | :group

  @type t :: %__MODULE__{
          key: String.t(),
          description: String.t(),
          kind: kind(),
          icon: String.t() | nil
        }
end

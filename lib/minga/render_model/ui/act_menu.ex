defmodule Minga.RenderModel.UI.ActMenu do
  @moduledoc "The shared compact action panel. Action identities are scoped to one offer."

  defmodule Row do
    @moduledoc "A menu choice and the direct key that reaches it without the menu."

    @enforce_keys [:id, :key, :label, :hint, :detail, :section, :destructive?]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: pos_integer(),
            key: String.t(),
            label: String.t(),
            hint: String.t(),
            detail: String.t(),
            section: String.t(),
            destructive?: boolean()
          }
  end

  @type role :: :neutral | :minga | :failure
  @type anchor :: :caret | {non_neg_integer(), non_neg_integer()}
  @enforce_keys [:id, :title, :role, :anchor, :query, :selected, :lead, :rows]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: pos_integer(),
          title: String.t(),
          role: role(),
          anchor: anchor() | nil,
          query: String.t(),
          selected: pos_integer() | nil,
          lead: [Row.t()],
          rows: [Row.t()]
        }
end

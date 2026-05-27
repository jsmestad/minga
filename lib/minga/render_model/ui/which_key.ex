defmodule Minga.RenderModel.UI.WhichKey do
  @moduledoc false

  @type binding :: %{
          key: String.t(),
          description: String.t(),
          kind: :command | :group,
          icon: String.t() | nil
        }

  @type t :: %__MODULE__{
          visible: boolean(),
          prefix: String.t(),
          page: non_neg_integer(),
          page_count: non_neg_integer(),
          bindings: [binding()]
        }

  @enforce_keys [:visible]
  defstruct visible: false,
            prefix: "",
            page: 0,
            page_count: 1,
            bindings: []
end

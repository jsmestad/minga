defmodule Minga.RenderModel.UI.Sidebars.Sidebar do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          semantic_kind: String.t(),
          icon: String.t(),
          order: non_neg_integer(),
          visible?: boolean(),
          focused?: boolean(),
          preferred_width: non_neg_integer(),
          badge_count: non_neg_integer() | nil
        }

  @enforce_keys [:id, :display_name, :semantic_kind, :order]
  defstruct id: "",
            display_name: "",
            semantic_kind: "",
            icon: "",
            order: 0,
            visible?: false,
            focused?: false,
            preferred_width: 0,
            badge_count: nil

  @spec focus(t(), boolean()) :: t()
  def focus(%__MODULE__{} = sidebar, focused?) when is_boolean(focused?) do
    %{sidebar | focused?: focused?}
  end
end

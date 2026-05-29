defmodule Minga.RenderModel.UI.TabBar do
  @moduledoc """
  Semantic tab bar model for GUI adapters.

  The model carries visible tab facts only. The GUI adapter owns protocol flag packing, active index calculation, and cache fingerprints.
  """

  alias Minga.RenderModel.UI.TabBar.Tab

  @type t :: %__MODULE__{
          visible?: boolean(),
          active_tab_id: non_neg_integer() | nil,
          tabs: [Tab.t()]
        }

  defstruct visible?: false,
            active_tab_id: nil,
            tabs: []
end

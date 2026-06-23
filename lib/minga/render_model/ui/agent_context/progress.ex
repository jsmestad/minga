defmodule Minga.RenderModel.UI.AgentContext.Progress do
  @moduledoc false

  @type t :: %__MODULE__{
          active_action: String.t(),
          tool_count: non_neg_integer(),
          file_count: non_neg_integer(),
          review_hint: String.t()
        }

  defstruct active_action: "",
            tool_count: 0,
            file_count: 0,
            review_hint: ""
end

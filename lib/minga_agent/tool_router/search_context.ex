defmodule MingaAgent.ToolRouter.SearchContext do
  @moduledoc """
  Trusted execution and filtering context for routed search tools.

  `exec_path` is the physical directory searched by tools. It may be a ProjectView or changeset overlay. `filter_root` is the logical project path used for ignore filtering and result interpretation.
  """

  @enforce_keys [:exec_path, :filter_root]
  defstruct [:exec_path, :filter_root]

  @type t :: %__MODULE__{
          exec_path: String.t(),
          filter_root: String.t()
        }
end

defmodule Minga.SystemObserver.ProcessSnapshot do
  @moduledoc """
  A point-in-time snapshot of a single BEAM process's metrics.

  Captured via `Process.info/2` during the on-demand polling tier.
  """

  @enforce_keys [:memory, :message_queue_len, :reductions]
  defstruct [
    :memory,
    :message_queue_len,
    :reductions,
    :current_function,
    :registered_name,
    :parent_pid,
    :child_type,
    :process_class
  ]

  @type child_type :: :supervisor | :worker | :unknown
  @type process_class :: :supervisor | :buffer | :agent_session | :lsp | :service | :worker

  @type t :: %__MODULE__{
          memory: non_neg_integer(),
          message_queue_len: non_neg_integer(),
          reductions: non_neg_integer(),
          current_function: {module(), atom(), arity()} | nil,
          registered_name: atom() | nil,
          parent_pid: pid() | nil,
          child_type: child_type(),
          process_class: process_class()
        }
end

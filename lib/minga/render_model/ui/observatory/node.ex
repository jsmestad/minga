defmodule Minga.RenderModel.UI.Observatory.Node do
  @moduledoc """
  One process row in the semantic GUI observatory model.
  """

  @type process_class :: :supervisor | :buffer | :agent_session | :lsp | :service | :worker

  @type t :: %__MODULE__{
          pid: pid(),
          parent_pid: pid() | nil,
          name: String.t(),
          process_class: process_class(),
          depth: non_neg_integer(),
          memory: non_neg_integer(),
          message_queue_len: non_neg_integer(),
          reductions: non_neg_integer(),
          sparkline_values: [float()]
        }

  @enforce_keys [
    :pid,
    :parent_pid,
    :name,
    :process_class,
    :depth,
    :memory,
    :message_queue_len,
    :reductions,
    :sparkline_values
  ]
  defstruct [
    :pid,
    :parent_pid,
    :name,
    :process_class,
    :depth,
    :memory,
    :message_queue_len,
    :reductions,
    :sparkline_values
  ]
end

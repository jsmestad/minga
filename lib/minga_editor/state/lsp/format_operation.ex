defmodule MingaEditor.State.LSP.FormatOperation do
  @moduledoc "Lifecycle data for one asynchronous LSP formatting request."

  alias Minga.LSP.PositionEncoding
  alias MingaEditor.Commands.BufferManagement

  @enforce_keys [
    :client,
    :ref,
    :buffer,
    :version,
    :encoding,
    :spinner_timer,
    :cancellable_timer,
    :timeout_timer
  ]
  defstruct [
    :client,
    :ref,
    :buffer,
    :version,
    :encoding,
    :continuation,
    :spinner_timer,
    :cancellable_timer,
    :timeout_timer
  ]

  @type t :: %__MODULE__{
          client: pid(),
          ref: reference(),
          buffer: pid(),
          version: non_neg_integer(),
          encoding: PositionEncoding.encoding(),
          continuation: BufferManagement.save_continuation() | nil,
          spinner_timer: reference(),
          cancellable_timer: reference(),
          timeout_timer: reference()
        }

  @doc "Builds a formatting operation from captured request data."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc "Returns every Editor-owned timer reference for this operation."
  @spec timer_refs(t()) :: [reference()]
  def timer_refs(%__MODULE__{} = operation) do
    [operation.spinner_timer, operation.cancellable_timer, operation.timeout_timer]
  end
end

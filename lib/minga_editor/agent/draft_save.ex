defmodule MingaEditor.Agent.DraftSave do
  @moduledoc "Tracks one composer's save acknowledgement without owning its text."

  alias MingaAgent.DraftSnapshot

  @type target :: {pid(), String.t()}
  @type marker :: {non_neg_integer(), DraftSnapshot.position()}
  @type revision :: non_neg_integer()
  @type request ::
          {:loading, reference(), marker()}
          | {:ready, revision(), marker() | nil}
          | {:saving, reference(), revision(), marker() | nil, marker()}
          | :blocked
  @type t :: %__MODULE__{
          target: target(),
          buffer: pid(),
          request: request(),
          timer: reference() | nil,
          attachments: [DraftSnapshot.attachment()]
        }

  @enforce_keys [:target, :buffer, :request]
  defstruct [:target, :buffer, :request, :timer, attachments: []]

  @doc "Tracks an in-flight read for the original composer marker."
  @spec loading(target(), pid(), reference(), marker()) :: t()
  def loading(target, buffer, ref, marker),
    do: %__MODULE__{target: target, buffer: buffer, request: {:loading, ref, marker}}

  @doc "Accepts a record revision and its restored attachment references."
  @spec loaded(t(), revision(), marker() | nil, DraftSnapshot.t() | nil) :: t()
  def loaded(%__MODULE__{request: {:loading, _, _}} = save, revision, marker, draft) do
    attachments = if draft, do: draft.attachments, else: []
    %{save | request: {:ready, revision, marker}, attachments: attachments}
  end

  @doc "Coalesces edits while a save timer is already armed."
  @spec schedule(t(), reference()) :: {:ok, t()} | :pending
  def schedule(%__MODULE__{timer: nil, request: {:ready, _, _}} = save, token),
    do: {:ok, %{save | timer: token}}

  def schedule(%__MODULE__{}, _token), do: :pending

  @doc "Consumes only the due timer for this composer."
  @spec due(t(), reference()) :: {:ok, t()} | :stale
  def due(%__MODULE__{timer: token} = save, token), do: {:ok, %{save | timer: nil}}
  def due(%__MODULE__{}, _token), do: :stale

  @doc "Associates a restored prompt process with the same saved record."
  @spec restore_buffer(t(), pid()) :: t()
  def restore_buffer(%__MODULE__{} = save, buffer), do: %{save | buffer: buffer}

  @doc "Admits a save only when the composer is newer than its last durable marker."
  @spec begin_save(t(), reference(), marker()) :: {:ok, revision(), t()} | :unchanged | :pending
  def begin_save(%__MODULE__{request: {:ready, _, marker}}, _ref, marker), do: :unchanged

  def begin_save(%__MODULE__{request: {:ready, revision, previous}} = save, ref, marker),
    do: {:ok, revision, %{save | request: {:saving, ref, revision, previous, marker}}}

  def begin_save(%__MODULE__{}, _ref, _marker), do: :pending

  @doc "Acknowledges only the write captured by this request."
  @spec saved(t(), reference(), revision()) :: {:ok, t()} | :stale
  def saved(%__MODULE__{request: {:saving, ref, _, _, marker}} = save, ref, revision),
    do: {:ok, %{save | request: {:ready, revision, marker}}}

  def saved(%__MODULE__{}, _ref, _revision), do: :stale

  @doc "Blocks a stale target or makes a refused write retryable on a later edit."
  @spec failed(t(), reference(), :retryable | :blocked) :: {:ok, t()} | :stale
  def failed(%__MODULE__{request: {:saving, ref, revision, previous, _}} = save, ref, :retryable),
    do: {:ok, %{save | request: {:ready, revision, previous}, timer: nil}}

  def failed(%__MODULE__{request: {:saving, ref, _, _, _}} = save, ref, :blocked),
    do: {:ok, %{save | request: :blocked, timer: nil}}

  def failed(%__MODULE__{request: {:loading, ref, _}} = save, ref, _reason),
    do: {:ok, %{save | request: :blocked, timer: nil}}

  def failed(%__MODULE__{}, _ref, _reason), do: :stale
end

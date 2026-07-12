defmodule Minga.Parser.BufferRegistration do
  @moduledoc """
  Parser synchronization state for one registered editor buffer.

  All transitions live here so the manager remains the sole process owner while registration invariants stay explicit and independently testable.
  """

  alias Minga.Buffer.ChangeLog
  alias Minga.Parser.BufferConfig

  @type phase ::
          :idle
          | {:awaiting_snapshot, reference()}
          | {:parsing, pos_integer(), ChangeLog.sequence()}

  @enforce_keys [:id, :config, :generation]
  defstruct [
    :id,
    :config,
    :generation,
    synced_sequence: 0,
    latest_dirty_sequence: 0,
    last_completed_version: 0,
    phase: :idle,
    force_full?: true
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          config: BufferConfig.t(),
          generation: reference(),
          synced_sequence: ChangeLog.sequence(),
          latest_dirty_sequence: ChangeLog.sequence(),
          last_completed_version: non_neg_integer(),
          phase: phase(),
          force_full?: boolean()
        }

  @doc "Creates a registration that requires an initial full parse."
  @spec new(pos_integer(), BufferConfig.t(), reference()) :: t()
  def new(id, %BufferConfig{} = config, generation) when is_reference(generation) do
    %__MODULE__{id: id, config: config, generation: generation}
  end

  @doc "Records the newest observed buffer change sequence."
  @spec mark_dirty(t(), ChangeLog.sequence()) :: t()
  def mark_dirty(%__MODULE__{} = registration, sequence) when sequence >= 0 do
    %{registration | latest_dirty_sequence: max(sequence, registration.latest_dirty_sequence)}
  end

  @doc "Returns whether an idle registration has synchronization work."
  @spec pumpable?(t()) :: boolean()
  def pumpable?(%__MODULE__{phase: :idle, force_full?: true}), do: true

  def pumpable?(%__MODULE__{phase: :idle} = registration) do
    registration.latest_dirty_sequence > registration.synced_sequence
  end

  def pumpable?(%__MODULE__{}), do: false

  @doc "Returns the cursor to request from the buffer."
  @spec snapshot_cursor(t()) :: :full | ChangeLog.sequence()
  def snapshot_cursor(%__MODULE__{force_full?: true}), do: :full
  def snapshot_cursor(%__MODULE__{synced_sequence: sequence}), do: sequence

  @doc "Marks an asynchronous snapshot request as in flight."
  @spec await_snapshot(t(), reference()) :: t()
  def await_snapshot(%__MODULE__{phase: :idle} = registration, token) when is_reference(token) do
    %{registration | phase: {:awaiting_snapshot, token}}
  end

  @doc "Returns whether a snapshot token belongs to the current request."
  @spec awaiting?(t(), reference()) :: boolean()
  def awaiting?(%__MODULE__{phase: {:awaiting_snapshot, token}}, token), do: true
  def awaiting?(%__MODULE__{}, _token), do: false

  @doc "Marks a parser version and snapshot target as in flight."
  @spec begin_parse(t(), pos_integer(), ChangeLog.sequence(), boolean()) :: t()
  def begin_parse(%__MODULE__{} = registration, version, target_sequence, full?) do
    %{
      registration
      | phase: {:parsing, version, target_sequence},
        force_full?: registration.force_full? and not full?
    }
  end

  @doc "Completes an unchanged snapshot without parser emission."
  @spec complete_unchanged(t(), ChangeLog.sequence()) :: t()
  def complete_unchanged(%__MODULE__{} = registration, sequence) do
    %{registration | phase: :idle, synced_sequence: sequence}
  end

  @doc "Completes only the matching parser version."
  @spec complete_parse(t(), pos_integer()) :: {:ok, t()} | :stale
  def complete_parse(%__MODULE__{phase: {:parsing, version, target}} = registration, version) do
    {:ok,
     %{
       registration
       | phase: :idle,
         synced_sequence: target,
         last_completed_version: version,
         force_full?: false
     }}
  end

  def complete_parse(%__MODULE__{}, _version), do: :stale

  @doc "Returns whether the parser is synchronized through the required buffer sequence."
  @spec synchronized?(t(), ChangeLog.sequence()) :: boolean()
  def synchronized?(%__MODULE__{phase: :idle, synced_sequence: synced}, required_sequence) do
    synced >= required_sequence
  end

  def synchronized?(%__MODULE__{}, _required_sequence), do: false

  @doc "Returns whether a version belongs to the current or most recently completed parse."
  @spec accepts_version?(t(), pos_integer()) :: boolean()
  def accepts_version?(%__MODULE__{phase: {:parsing, version, _target}}, version), do: true

  def accepts_version?(%__MODULE__{last_completed_version: version}, version) when version > 0,
    do: true

  def accepts_version?(%__MODULE__{}, _version), do: false

  @doc "Resets volatile parser state and requires a fresh full snapshot."
  @spec restart(t()) :: t()
  def restart(%__MODULE__{} = registration) do
    %{
      registration
      | phase: :idle,
        synced_sequence: 0,
        last_completed_version: 0,
        force_full?: true
    }
  end
end

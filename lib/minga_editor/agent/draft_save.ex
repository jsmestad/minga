defmodule MingaEditor.Agent.DraftSave do
  @moduledoc "Tracks one composer's save acknowledgement without owning its text."

  alias MingaAgent.DraftSnapshot
  alias MingaAgent.DraftAttachment

  @type target :: {pid(), String.t()}
  @type marker :: {non_neg_integer(), DraftSnapshot.position()}
  @type revision :: non_neg_integer()
  @type request ::
          {:loading, reference(), marker()}
          | {:ready, revision(), marker() | nil}
          | {:saving, reference(), revision(), marker() | nil, marker()}
          | {:attaching, reference(), revision(), marker() | nil, marker()}
          | {:removing, reference(), revision(), marker() | nil, marker(),
             [DraftSnapshot.attachment()]}
          | :blocked
          | :attachment_review_required
          | {:reviewing_attachments, reference()}
  @type t :: %__MODULE__{
          target: target(),
          buffer: pid(),
          request: request(),
          timer: reference() | nil,
          offer: pos_integer() | nil,
          attachments: [DraftSnapshot.attachment()]
        }

  @enforce_keys [:target, :buffer, :request]
  defstruct [:target, :buffer, :request, :timer, :offer, attachments: []]

  @doc "Tracks an in-flight read for the original composer marker."
  @spec loading(target(), pid(), reference(), marker()) :: t()
  def loading(target, buffer, ref, marker),
    do: %__MODULE__{target: target, buffer: buffer, request: {:loading, ref, marker}}

  @doc "Accepts a record revision and its restored attachment references."
  @spec loaded(t(), revision(), marker() | nil, DraftSnapshot.t() | nil) :: t()
  def loaded(%__MODULE__{request: {:loading, _, _}} = save, revision, marker, draft) do
    attachments = if draft, do: draft.attachments, else: []
    %{save | request: {:ready, revision, marker}, attachments: attachments, offer: next_offer()}
  end

  @doc "Keeps the saved attachment identities when incoming recovery conflicts with live text."
  @spec conflicted(t(), DraftSnapshot.t()) :: t()
  def conflicted(%__MODULE__{request: {:loading, _, _}} = save, %DraftSnapshot{} = draft),
    do: %{save | request: :blocked, attachments: draft.attachments, timer: nil}

  @doc "Begins an explicit attachment reload without replacing the live composer."
  @spec review_attachments(t(), reference()) :: t()
  def review_attachments(%__MODULE__{request: :attachment_review_required} = save, ref),
    do: %{save | request: {:reviewing_attachments, ref}}

  @doc "Installs the reloaded attachment set and leaves live text dirty for autosave."
  @spec attachments_reviewed(t(), revision(), DraftSnapshot.t() | nil) :: t()
  def attachments_reviewed(
        %__MODULE__{request: {:reviewing_attachments, _}} = save,
        revision,
        draft
      ) do
    attachments = if draft, do: draft.attachments, else: []
    %{save | request: {:ready, revision, nil}, attachments: attachments, offer: next_offer()}
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

  @doc "Admits a draft mutation even when the text and caret have not changed."
  @spec begin_attachment(t(), reference(), marker()) :: {:ok, revision(), t()} | :pending
  def begin_attachment(%__MODULE__{request: {:ready, revision, previous}} = save, ref, marker),
    do: {:ok, revision, %{save | request: {:attaching, ref, revision, previous, marker}}}

  def begin_attachment(%__MODULE__{}, _ref, _marker), do: :pending

  @doc "Stages removal of an exact displayed snapshot without removing it before the write succeeds."
  @spec begin_removal(t(), reference(), marker(), DraftAttachment.identity()) ::
          {:ok, revision(), t(), [DraftSnapshot.attachment()]} | :missing | :pending
  def begin_removal(
        %__MODULE__{request: {:ready, revision, previous}} = save,
        ref,
        marker,
        identity
      ) do
    case Enum.split_while(save.attachments, &(DraftAttachment.identity(&1) != identity)) do
      {_prefix, []} ->
        :missing

      {prefix, [_removed | rest]} ->
        remaining = prefix ++ rest
        pending = %{save | request: {:removing, ref, revision, previous, marker, remaining}}
        {:ok, revision, pending, remaining}
    end
  end

  def begin_removal(%__MODULE__{}, _ref, _marker, _identity), do: :pending

  @doc "Acknowledges only the write captured by this request."
  @spec saved(t(), reference(), revision()) :: {:ok, t()} | :stale
  def saved(%__MODULE__{request: {:saving, ref, _, _, marker}} = save, ref, revision),
    do: {:ok, %{save | request: {:ready, revision, marker}}}

  def saved(
        %__MODULE__{request: {:removing, ref, _, _, marker, remaining}} = save,
        ref,
        revision
      ),
      do:
        {:ok,
         %{
           save
           | request: {:ready, revision, marker},
             attachments: remaining,
             offer: next_offer()
         }}

  def saved(%__MODULE__{}, _ref, _revision), do: :stale

  @doc "Installs only the attachment returned by the confirmed save."
  @spec attached(t(), reference(), revision(), DraftSnapshot.attachment()) :: {:ok, t()} | :stale
  def attached(
        %__MODULE__{request: {:attaching, ref, _, _, marker}} = save,
        ref,
        revision,
        attachment
      ) do
    {:ok,
     %{
       save
       | request: {:ready, revision, marker},
         attachments: [attachment | save.attachments],
         offer: next_offer()
     }}
  end

  def attached(%__MODULE__{}, _ref, _revision, _attachment), do: :stale

  @doc "Clears live attachment metadata only once its captured text was accepted for submission."
  @spec sent(t(), revision(), marker()) :: t()
  def sent(%__MODULE__{request: {:ready, _, _}} = save, revision, marker),
    do: %{save | request: {:ready, revision, marker}, attachments: [], offer: next_offer()}

  @doc "Validates the offer echoed by the frontend against this composer and its displayed attachment set."
  @spec submission(t() | nil, pos_integer() | nil) ::
          :ordinary | {:attached, target(), [DraftAttachment.identity()]} | {:error, String.t()}
  def submission(%__MODULE__{offer: offer} = save, offer) when is_integer(offer),
    do: submission(save)

  def submission(%__MODULE__{attachments: []} = save, nil), do: submission(save)
  def submission(nil, nil), do: :ordinary

  def submission(_save, _offer),
    do: {:error, "Draft attachments changed. Review them and send again."}

  @spec next_offer() :: pos_integer()
  defp next_offer, do: System.unique_integer([:positive, :monotonic])

  @doc "Returns the displayed set and blocks sending while its first restoration or a mutation is pending."
  @spec submission(t() | nil) ::
          :ordinary | {:attached, target(), [DraftAttachment.identity()]} | {:error, String.t()}
  def submission(%__MODULE__{request: {:loading, _, _}}),
    do: {:error, "Wait for the saved composer draft to load."}

  def submission(%__MODULE__{request: {:attaching, _, _, _, _}}),
    do: {:error, "Wait for the selection snapshot to finish saving."}

  def submission(%__MODULE__{request: {:removing, _, _, _, _, _}}),
    do: {:error, "Wait for the attachment removal to finish saving."}

  def submission(%__MODULE__{request: {:saving, _, _, _, _}, attachments: [_ | _]}),
    do: {:error, "Wait for the composer draft to finish saving."}

  def submission(%__MODULE__{request: :attachment_review_required}),
    do:
      {:error,
       "Reopen the saved draft before sending. The last attachment change could not be confirmed."}

  def submission(%__MODULE__{request: {:reviewing_attachments, _}}),
    do: {:error, "Wait for the saved attachments to reload."}

  def submission(%__MODULE__{request: :blocked, attachments: [_ | _]}),
    do: {:error, "Reopen the saved draft before sending its attachments."}

  def submission(%__MODULE__{target: target, attachments: [_ | _] = attachments}) do
    identities = Enum.map(attachments, &DraftAttachment.identity/1)

    if nil in identities,
      do: {:error, "The composer has an unsupported attachment. Remove it before sending."},
      else: {:attached, target, identities}
  end

  def submission(_save), do: :ordinary

  @doc "Blocks a stale target or makes a refused write retryable on a later edit."
  @spec failed(t(), reference(), :retryable | :blocked) :: {:ok, t()} | :stale
  def failed(%__MODULE__{request: {phase, ref, revision, previous, _}} = save, ref, :retryable)
      when phase in [:saving, :attaching],
      do: {:ok, %{save | request: {:ready, revision, previous}, timer: nil}}

  def failed(%__MODULE__{request: {:attaching, ref, _, _, _}} = save, ref, :blocked),
    do: {:ok, %{save | request: :attachment_review_required, timer: nil}}

  def failed(%__MODULE__{request: {:saving, ref, _, _, _}} = save, ref, :blocked),
    do: {:ok, %{save | request: :blocked, timer: nil}}

  def failed(
        %__MODULE__{request: {:removing, ref, revision, previous, _, _}} = save,
        ref,
        :retryable
      ),
      do: {:ok, %{save | request: {:ready, revision, previous}, timer: nil}}

  def failed(%__MODULE__{request: {:removing, ref, _, _, _, _}} = save, ref, :blocked),
    do: {:ok, %{save | request: :attachment_review_required, timer: nil}}

  def failed(%__MODULE__{request: {:loading, ref, _}} = save, ref, _reason),
    do: {:ok, %{save | request: :blocked, timer: nil}}

  def failed(%__MODULE__{request: {:reviewing_attachments, ref}} = save, ref, _reason),
    do: {:ok, %{save | request: :attachment_review_required, timer: nil}}

  def failed(%__MODULE__{}, _ref, _reason), do: :stale
end

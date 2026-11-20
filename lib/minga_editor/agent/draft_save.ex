defmodule MingaEditor.Agent.DraftSave do
  @moduledoc "Tracks one composer's save acknowledgement without owning its text."

  alias MingaAgent.DraftSnapshot
  alias MingaAgent.DraftAttachment
  alias MingaAgent.Session.TurnExecution

  @type target :: {pid(), String.t()}
  @type marker :: {non_neg_integer(), DraftSnapshot.position()}
  @type revision :: non_neg_integer()
  @type queue_admission :: {pos_integer(), String.t(), TurnExecution.prompt_kind()}
  @type request ::
          {:loading, reference(), marker()}
          | {:ready, revision(), marker() | nil}
          | {:saving, reference(), revision(), marker() | nil, marker()}
          | {:recalling, reference(), revision(), marker() | nil, marker()}
          | {:queueing, reference(), revision(), marker() | nil, marker(), queue_admission()}
          | :recall_conflicted
          | {:reloading_recall, reference(), marker()}
          | {:attaching, reference(), revision(), marker() | nil, marker()}
          | {:removing, reference(), revision(), marker() | nil, marker(),
             [DraftSnapshot.attachment()]}
          | {:submitting, reference(), revision(), marker() | nil, marker(), String.t()}
          | {:submission_unconfirmed, revision(), String.t(), marker()}
          | {:checking_submission, reference(), revision(), String.t(), marker()}
          | {:load_failed, marker()}
          | :blocked
          | :attachment_review_required
          | {:reviewing_attachments, reference()}
  @type t :: %__MODULE__{
          target: target(),
          buffer: pid(),
          request: request(),
          timer: reference() | nil,
          offer: pos_integer() | nil,
          retirement: {reference(), TurnExecution.queue_receipt()} | nil,
          rearm_on_save_failure: boolean(),
          attachments: [DraftSnapshot.attachment()]
        }

  @enforce_keys [:target, :buffer, :request]
  defstruct [
    :target,
    :buffer,
    :request,
    :timer,
    :offer,
    :retirement,
    attachments: [],
    rearm_on_save_failure: false
  ]

  @doc "Tracks an in-flight read for the original composer marker."
  @spec loading(target(), pid(), reference(), marker()) :: t()
  def loading(target, buffer, ref, marker),
    do: %__MODULE__{target: target, buffer: buffer, request: {:loading, ref, marker}}

  @doc "Accepts a record revision and its restored attachment references."
  @spec loaded(t(), revision(), marker() | nil, DraftSnapshot.t() | nil) :: t()
  def loaded(%__MODULE__{request: {phase, _, _}} = save, revision, marker, draft)
      when phase in [:loading, :reloading_recall] do
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

  @doc "Reads the recalled draft again after the user has emptied the conflicting live input."
  @spec reload_recall(t(), reference(), marker()) :: t()
  def reload_recall(%__MODULE__{request: :recall_conflicted} = save, ref, marker),
    do: %{save | request: {:reloading_recall, ref, marker}}

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

  @doc "Remembers that a new driver is available if the old driver's autosave fails."
  @spec renew_saving_driver(t()) :: t()
  def renew_saving_driver(%__MODULE__{request: {:saving, _, _, _, _}} = save),
    do: %{save | rearm_on_save_failure: true}

  @doc "Moves autosave to the authenticated replacement of the same saved record."
  @spec rebind_writer(t(), pid()) :: t()
  def rebind_writer(%__MODULE__{target: {session, _}} = save, session), do: save

  def rebind_writer(%__MODULE__{target: {_, record}, request: {:ready, _, _}} = save, session),
    do: %{save | target: {session, record}, timer: nil}

  def rebind_writer(
        %__MODULE__{target: {_, record}, request: {:saving, _, revision, previous, _}} = save,
        session
      ),
      do: %{
        save
        | target: {session, record},
          request: {:ready, revision, previous},
          timer: nil,
          rearm_on_save_failure: false
      }

  @doc "Correlates receipt retirement separately from ongoing draft edits and saves."
  @spec retire_queue_receipt(t(), reference(), TurnExecution.queue_receipt()) :: t()
  def retire_queue_receipt(%__MODULE__{} = save, ref, receipt),
    do: %{save | retirement: {ref, receipt}}

  @doc "Forgets a receipt only after the original daemon confirms its retirement."
  @spec queue_receipt_retired(t(), reference()) :: t()
  def queue_receipt_retired(%__MODULE__{retirement: {ref, _}} = save, ref),
    do: %{save | retirement: nil}

  def queue_receipt_retired(%__MODULE__{} = save, _ref), do: save

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

  @doc "Freezes the captured live marker and owns the recall until its reply arrives."
  @spec begin_recall(t(), reference(), marker()) :: {:ok, revision(), t()} | :pending
  def begin_recall(%__MODULE__{request: {:ready, revision, previous}} = save, ref, marker),
    do:
      {:ok, revision,
       %{save | request: {:recalling, ref, revision, previous, marker}, timer: nil}}

  def begin_recall(%__MODULE__{}, _ref, _marker), do: :pending

  @doc "Binds a queue submission identity to the original live composer marker and revision."
  @spec begin_queue(t(), reference(), marker(), queue_admission()) ::
          {:ok, revision(), t()} | :pending
  def begin_queue(
        %__MODULE__{request: {:ready, revision, previous}, retirement: nil} = save,
        ref,
        marker,
        attempt
      ) do
    {:ok, revision,
     %{save | request: {:queueing, ref, revision, previous, marker, attempt}, timer: nil}}
  end

  def begin_queue(%__MODULE__{}, _ref, _marker, _attempt), do: :pending

  @doc "Moves only a pending queue acknowledgement to the replacement owner of the same record."
  @spec rebind_queue(t(), target(), pid()) ::
          {:ok, reference(), revision(), queue_admission(), t()} | :stale
  def rebind_queue(
        %__MODULE__{
          target: {_, record} = origin,
          request: {:queueing, _, revision, previous, marker, attempt}
        } = save,
        origin,
        replacement
      ) do
    ref = make_ref()
    pending = {:queueing, ref, revision, previous, marker, attempt}
    {:ok, ref, revision, attempt, %{save | target: {replacement, record}, request: pending}}
  end

  def rebind_queue(%__MODULE__{}, _origin, _replacement), do: :stale

  @doc "Clears only the attachment identities admitted by this acknowledged queue operation."
  @spec queue_saved(t(), reference(), revision(), marker() | nil) :: t()
  def queue_saved(
        %__MODULE__{request: {:queueing, ref, _, _, _, _}} = save,
        ref,
        revision,
        marker
      ),
      do: %{save | request: {:ready, revision, marker}, attachments: [], offer: next_offer()}

  @doc "Retires a refused submission without erasing the original live draft."
  @spec queue_refused(t(), reference(), :retryable | :blocked) :: t()
  def queue_refused(
        %__MODULE__{request: {:queueing, ref, revision, previous, _, _}} = save,
        ref,
        :retryable
      ),
      do: %{save | request: {:ready, revision, previous}}

  def queue_refused(%__MODULE__{request: {:queueing, ref, _, _, _, _}} = save, ref, :blocked),
    do: %{save | request: :blocked}

  @doc "Installs a confirmed recall or prevents autosave from overwriting a conflicting saved draft."
  @spec recall_result(
          t(),
          reference(),
          {:installed, revision(), marker(), DraftSnapshot.t()} | :conflict
        ) ::
          t()
  def recall_result(
        %__MODULE__{request: {:recalling, ref, _, _, _}} = save,
        ref,
        {:installed, revision, marker, draft}
      ) do
    %{
      save
      | request: {:ready, revision, marker},
        attachments: draft.attachments,
        offer: next_offer()
    }
  end

  def recall_result(%__MODULE__{request: {:recalling, ref, _, _, _}} = save, ref, :conflict),
    do: %{save | request: :recall_conflicted, offer: next_offer()}

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
    do: {:ok, %{save | request: {:ready, revision, marker}, rearm_on_save_failure: false}}

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

  @doc "Holds one remote submission outstanding without losing any newer composer edit."
  @spec begin_submission(t(), reference(), marker(), String.t()) :: {:ok, t()} | :pending
  def begin_submission(
        %__MODULE__{request: {:ready, revision, previous}} = save,
        ref,
        marker,
        id
      ),
      do: {:ok, %{save | request: {:submitting, ref, revision, previous, marker, id}, timer: nil}}

  def begin_submission(%__MODULE__{}, _ref, _marker, _id), do: :pending

  @doc "Queries the exact previous admission without retrying the prompt."
  @spec check_submission(t(), target(), reference()) :: t()
  def check_submission(
        %__MODULE__{
          target: {previous, id},
          request: {:submission_unconfirmed, revision, submission_id, marker}
        } = save,
        {session, id} = target,
        ref
      )
      when node(previous) == node(session),
      do: %{
        save
        | target: target,
          request: {:checking_submission, ref, revision, submission_id, marker}
      }

  @doc "Retires the sent attachment set while keeping a later live draft dirty."
  @spec submitted(t(), reference(), revision(), marker() | nil) :: {:ok, t()} | :stale
  def submitted(
        %__MODULE__{request: {:submitting, ref, _, _, _, _}} = save,
        ref,
        revision,
        marker
      ),
      do:
        {:ok, %{save | request: {:ready, revision, marker}, attachments: [], offer: next_offer()}}

  def submitted(
        %__MODULE__{request: {:checking_submission, ref, _, _, _}} = save,
        ref,
        revision,
        marker
      ),
      do:
        {:ok, %{save | request: {:ready, revision, marker}, attachments: [], offer: next_offer()}}

  def submitted(%__MODULE__{}, _ref, _revision, _marker), do: :stale

  @doc "Makes an exactly reconciled refusal retryable while retaining all live composer input."
  @spec submission_refused(t(), reference(), revision()) :: t()
  def submission_refused(
        %__MODULE__{request: {:checking_submission, ref, _, _, _}} = save,
        ref,
        revision
      ),
      do: %{save | request: {:ready, revision, nil}}

  @doc "Returns the attachment offer projected in the composer, if any."
  @spec attachment_offer(t() | nil) :: pos_integer() | nil
  def attachment_offer(%__MODULE__{offer: offer}), do: offer
  def attachment_offer(nil), do: nil

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

  def submission(%__MODULE__{request: {:queueing, _, _, _, _, _}}),
    do: {:error, "Wait for the saved queue submission to finish."}

  def submission(%__MODULE__{request: {:recalling, _, _, _, _}}),
    do: {:error, "Wait for the queued input to be recalled."}

  def submission(%__MODULE__{request: :recall_conflicted}),
    do:
      {:error, "The recalled input was saved separately. Reopen the saved draft before sending."}

  def submission(%__MODULE__{request: {:reloading_recall, _, _}}),
    do: {:error, "Wait for the recalled draft to reload."}

  def submission(%__MODULE__{request: {:load_failed, _}}),
    do: {:error, "Reconnect to the original Agent conversation to reload its saved draft."}

  def submission(%__MODULE__{request: {:attaching, _, _, _, _}}),
    do: {:error, "Wait for the selection snapshot to finish saving."}

  def submission(%__MODULE__{request: {:removing, _, _, _, _, _}}),
    do: {:error, "Wait for the attachment removal to finish saving."}

  def submission(%__MODULE__{request: {:submitting, _, _, _, _, _}}),
    do: {:error, "Wait for the original Agent conversation to confirm the send."}

  def submission(%__MODULE__{request: {:submission_unconfirmed, _, _, _}}),
    do: {:error, "Open Draft attachments to check whether the last send was accepted."}

  def submission(%__MODULE__{request: {:checking_submission, _, _, _, _}}),
    do: {:error, "Wait for the original conversation to check the last send."}

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
  @spec failed(t(), reference(), :retryable | :blocked | :unconfirmed) :: {:ok, t()} | :stale
  def failed(%__MODULE__{request: {phase, ref, revision, previous, _}} = save, ref, :retryable)
      when phase in [:saving, :attaching, :recalling],
      do:
        {:ok,
         %{save | request: {:ready, revision, previous}, timer: nil, rearm_on_save_failure: false}}

  def failed(%__MODULE__{request: {:attaching, ref, _, _, _}} = save, ref, :blocked),
    do: {:ok, %{save | request: :attachment_review_required, timer: nil}}

  def failed(%__MODULE__{request: {phase, ref, _, _, _}} = save, ref, :blocked)
      when phase in [:saving, :recalling],
      do: {:ok, %{save | request: :blocked, timer: nil, rearm_on_save_failure: false}}

  def failed(
        %__MODULE__{request: {:submitting, ref, revision, previous, _, _}} = save,
        ref,
        :retryable
      ),
      do: {:ok, %{save | request: {:ready, revision, previous}, timer: nil}}

  def failed(
        %__MODULE__{request: {:submitting, ref, revision, _, marker, id}} = save,
        ref,
        :unconfirmed
      ),
      do: {:ok, %{save | request: {:submission_unconfirmed, revision, id, marker}, timer: nil}}

  def failed(
        %__MODULE__{request: {:checking_submission, ref, revision, id, marker}} = save,
        ref,
        _reason
      ),
      do: {:ok, %{save | request: {:submission_unconfirmed, revision, id, marker}, timer: nil}}

  def failed(%__MODULE__{request: {:submitting, ref, _, _, _, _}} = save, ref, :blocked),
    do: {:ok, %{save | request: :attachment_review_required, timer: nil}}

  def failed(
        %__MODULE__{request: {:removing, ref, revision, previous, _, _}} = save,
        ref,
        :retryable
      ),
      do: {:ok, %{save | request: {:ready, revision, previous}, timer: nil}}

  def failed(%__MODULE__{request: {:removing, ref, _, _, _, _}} = save, ref, :blocked),
    do: {:ok, %{save | request: :attachment_review_required, timer: nil}}

  def failed(
        %__MODULE__{request: {:loading, ref, marker}, target: {session, _}} = save,
        ref,
        _reason
      )
      when node(session) != node(),
      do: {:ok, %{save | request: {:load_failed, marker}, timer: nil}}

  def failed(%__MODULE__{request: {:loading, ref, _}} = save, ref, _reason),
    do: {:ok, %{save | request: :blocked, timer: nil}}

  def failed(%__MODULE__{request: {:reloading_recall, ref, _}} = save, ref, _reason),
    do: {:ok, %{save | request: :recall_conflicted}}

  def failed(%__MODULE__{request: {:reviewing_attachments, ref}} = save, ref, _reason),
    do: {:ok, %{save | request: :attachment_review_required, timer: nil}}

  def failed(%__MODULE__{}, _ref, _reason), do: :stale
end

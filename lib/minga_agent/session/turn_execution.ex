defmodule MingaAgent.Session.TurnExecution do
  @moduledoc """
  Owns one session's execution mode, runtime phase, and turn-scoped resources.

  Transitions are pure. They return the next owned value or a domain outcome; `MingaAgent.Session` remains responsible for provider calls, notifications, broadcasts, transcript updates, and persistence.
  """

  alias MingaAgent.DraftSnapshot
  alias MingaAgent.EditBoundary
  alias MingaAgent.Event
  alias MingaAgent.Question
  alias MingaAgent.Question.Pending, as: PendingQuestion
  alias MingaAgent.Question.Target, as: QuestionTarget
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.ToolApproval
  alias MingaAgent.ToolApproval.Public, as: PublicApproval

  @typedoc "Execution mode, independent of whether a provider turn is active."
  @type mode :: :exec | :plan

  @typedoc "Tool trust lifetime."
  @type trust_scope :: :session | :turn

  @typedoc "Prompt content admitted to steering and follow-up queues."
  @type content :: String.t() | [ReqLLM.Message.ContentPart.t()]

  @typedoc "How an active turn should admit an additional prompt."
  @type prompt_kind :: :steering | :follow_up

  @typedoc "Whether a prompt starts a turn now or joins one of the active turn's queues."
  @type prompt_admission :: {:send_now, t()} | {:queued, t()} | {:error, :prompt_queue_full}

  @type queued_input ::
          {id :: pos_integer(), revision :: pos_integer(), content(),
           [DraftSnapshot.attachment()], String.t() | nil}
  @type queue_receipt ::
          {id :: pos_integer(), submission_id :: String.t(), prompt_kind(),
           committed_revision :: pos_integer()}
  @type pending_inputs ::
          {next_id :: pos_integer(), [queued_input()], [queued_input()], [queue_receipt()]}
  @max_pending_inputs 32
  @max_pending_bytes 16 * 1024 * 1024
  @max_queue_receipts 64

  @typedoc "An active provider tool identified by its stable call ID."
  @type active_tool :: {tool_call_id :: String.t(), name :: String.t()}

  @typedoc "Provider activity within one active turn."
  @type activity ::
          :starting | :thinking | :completion | {:tool_execution, [active_tool(), ...]}

  @type interaction :: ToolApproval.t() | PendingQuestion.t() | nil

  @typedoc "Runtime phase. A turn has one blocking interaction slot, independent of provider activity and nonterminal errors."
  @type phase ::
          :idle
          | {:active, activity(), interaction(), String.t() | nil}
          | {:failure, String.t()}

  @typedoc "Public status retained at the Session API boundary."
  @type status :: :idle | :plan | :thinking | :tool_executing | :error
  @type display_status :: status() | :approval_waiting

  @typedoc "Supported approval response."
  @type approval_decision :: :approve | :approve_session | :approve_turn | :reject

  @typedoc "Canonical turn execution state."
  @type t :: %__MODULE__{
          mode: mode(),
          phase: phase(),
          trust_levels: %{String.t() => trust_scope()},
          pending_auto_approvals: %{String.t() => trust_scope()},
          next_prompt_id: pos_integer(),
          steering_queue: [queued_input()],
          follow_up_queue: [queued_input()],
          queue_receipts: [queue_receipt()],
          boundaries: %{String.t() => EditBoundary.t()}
        }

  defstruct mode: :exec,
            phase: :idle,
            trust_levels: %{},
            pending_auto_approvals: %{},
            next_prompt_id: 1,
            steering_queue: [],
            follow_up_queue: [],
            queue_receipts: [],
            boundaries: %{}

  @doc "Builds an idle execution state."
  @spec new(mode()) :: t()
  def new(mode \\ :exec) when mode in [:exec, :plan], do: %__MODULE__{mode: mode}

  @doc "Returns the current execution mode."
  @spec mode(t()) :: mode()
  def mode(%__MODULE__{mode: mode}), do: mode

  @doc "Returns the current runtime phase name."
  @spec phase(t()) ::
          :idle
          | :starting
          | :thinking
          | :approval_waiting
          | :question_waiting
          | :tool_execution
          | :completion
          | :failure
  def phase(%__MODULE__{phase: {:active, _activity, %ToolApproval{}, _error}}),
    do: :approval_waiting

  def phase(%__MODULE__{phase: {:active, _activity, %PendingQuestion{}, _error}}),
    do: :question_waiting

  def phase(%__MODULE__{phase: {:active, activity, nil, _error}}),
    do: activity_phase(activity)

  def phase(%__MODULE__{phase: {:failure, _message}}), do: :failure
  def phase(%__MODULE__{phase: :idle}), do: :idle

  @doc "Derives the stable public Session status."
  @spec status(t()) :: status()
  def status(%__MODULE__{mode: :plan}), do: :plan
  def status(%__MODULE__{phase: :idle}), do: :idle

  def status(%__MODULE__{phase: {:active, _activity, _approval, message}})
      when is_binary(message),
      do: :error

  def status(%__MODULE__{phase: {:active, activity, _approval, nil}}),
    do: activity_status(activity)

  def status(%__MODULE__{phase: {:failure, _message}}), do: :error

  @doc "Projects authoritative approval waiting without changing execution status."
  @spec display_status(t()) :: display_status()
  def display_status(%__MODULE__{phase: {:active, _activity, %ToolApproval{}, _error}}),
    do: :approval_waiting

  def display_status(%__MODULE__{} = execution), do: status(execution)

  @doc "Projects foreground values, preserving an absent runtime, without querying a Session."
  @spec display_status(status() | nil, PublicApproval.t() | nil) :: display_status() | nil
  def display_status(_raw_status, %PublicApproval{}), do: :approval_waiting
  def display_status(raw_status, nil), do: raw_status

  @doc "Returns true while provider work belongs to the current turn."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{phase: {:active, _activity, _approval, _error}}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "Returns the current pending approval, if any."
  @spec pending_approval(t()) :: ToolApproval.t() | nil
  def pending_approval(%__MODULE__{
        phase: {:active, _activity, %ToolApproval{} = approval, _error}
      }),
      do: approval

  def pending_approval(%__MODULE__{}), do: nil

  @doc "Returns the current question and its tool call identity without changing the turn."
  @spec pending_question(t()) :: PendingQuestion.t() | nil
  def pending_question(%__MODULE__{phase: {:active, _, %PendingQuestion{} = wait, _}}),
    do: wait

  def pending_question(%__MODULE__{}), do: nil

  @doc "Returns the current error message, if any."
  @spec error(t()) :: String.t() | nil
  def error(%__MODULE__{phase: {:active, _activity, _approval, message}})
      when is_binary(message),
      do: message

  def error(%__MODULE__{phase: {:failure, message}}), do: message
  def error(%__MODULE__{}), do: nil

  @doc "Returns active tools in provider start order."
  @spec active_tools(t()) :: [active_tool()]
  def active_tools(%__MODULE__{
        phase: {:active, {:tool_execution, tools}, _approval, _error}
      }),
      do: tools

  def active_tools(%__MODULE__{}), do: []

  @doc "Returns the most recently started active tool name."
  @spec active_tool_name(t()) :: String.t() | nil
  def active_tool_name(%__MODULE__{
        phase: {:active, {:tool_execution, tools}, _approval, _error}
      }) do
    # The collection preserves provider start order and stays bounded by active tool calls.
    # credo:disable-for-next-line ExSlop.Check.Refactor.ListLast
    case List.last(tools) do
      {_id, name} -> name
      nil -> nil
    end
  end

  def active_tool_name(%__MODULE__{}), do: nil

  @doc "Returns the name for one active tool call."
  @spec tool_name(t(), String.t()) :: {:ok, String.t()} | {:error, :tool_not_active}
  def tool_name(
        %__MODULE__{phase: {:active, {:tool_execution, tools}, _approval, _error}},
        tool_call_id
      )
      when is_binary(tool_call_id) do
    case List.keyfind(tools, tool_call_id, 0) do
      {_id, name} -> {:ok, name}
      nil -> {:error, :tool_not_active}
    end
  end

  def tool_name(%__MODULE__{}, tool_call_id) when is_binary(tool_call_id),
    do: {:error, :tool_not_active}

  @doc "Begins a provider turn from an inactive state."
  @spec begin_turn(t()) :: {:ok, t()} | {:error, :turn_active}
  def begin_turn(%__MODULE__{phase: :idle} = execution),
    do: {:ok, activate(execution, :starting)}

  def begin_turn(%__MODULE__{phase: {:failure, _message}} = execution),
    do: {:ok, activate(execution, :starting)}

  def begin_turn(%__MODULE__{phase: {:active, _activity, _approval, _error}}),
    do: {:error, :turn_active}

  @doc "Accepts the provider's turn-start event."
  @spec provider_started(t()) :: {:ok, t()} | {:error, :invalid_phase}
  def provider_started(%__MODULE__{phase: {:active, :starting, nil, _error}} = execution),
    do: {:ok, activate(execution, :thinking)}

  def provider_started(%__MODULE__{}),
    do: {:error, :invalid_phase}

  @doc "Moves an active turn into approval waiting."
  @spec request_approval(t(), ToolApproval.t()) :: {:accepted, t()} | :rejected
  def request_approval(
        %__MODULE__{phase: {:active, activity, nil, error}} = execution,
        %ToolApproval{} = approval
      ),
      do: {:accepted, %{execution | phase: {:active, activity, approval, error}}}

  def request_approval(%__MODULE__{}, %ToolApproval{}), do: :rejected

  @doc "Installs an admitted clarification when the active turn has no blocking interaction."
  @spec request_question(t(), PendingQuestion.t()) ::
          {:ok, t()} | {:error, :turn_not_active | :interaction_pending}
  def request_question(
        %__MODULE__{phase: {:active, activity, nil, error}} = execution,
        %PendingQuestion{} = wait
      ),
      do: {:ok, %{execution | phase: {:active, activity, wait, error}}}

  def request_question(%__MODULE__{phase: {:active, _, _, _}}, %PendingQuestion{}),
    do: {:error, :interaction_pending}

  def request_question(%__MODULE__{}, %PendingQuestion{}), do: {:error, :turn_not_active}

  @doc "Resolves only the named question. Invalid answers leave the wait active."
  @spec resolve_question(t(), QuestionTarget.t(), Question.response()) ::
          {:ok, PendingQuestion.t(), Question.outcome(), t()}
          | {:error, :question_not_found | :invalid_answer}
  def resolve_question(
        %__MODULE__{phase: {:active, activity, %PendingQuestion{target: target} = wait, error}} =
          execution,
        target,
        response
      ) do
    with {:ok, outcome} <- Question.resolve(wait.question, response) do
      {:ok, wait, outcome, %{execution | phase: {:active, activity, nil, error}}}
    end
  end

  def resolve_question(%__MODULE__{}, _target, _response), do: {:error, :question_not_found}

  @doc "Withdraws a question without treating interruption as an answer or cancellation."
  @spec interrupt_question(t()) :: {:interrupted, PendingQuestion.t(), t()} | :no_question
  def interrupt_question(
        %__MODULE__{phase: {:active, activity, %PendingQuestion{} = wait, error}} = execution
      ),
      do: {:interrupted, wait, %{execution | phase: {:active, activity, nil, error}}}

  def interrupt_question(%__MODULE__{}), do: :no_question

  @doc "Resolves the matching pending approval and restores the active runtime phase."
  @spec resolve_approval(t(), String.t(), approval_decision()) ::
          {:ok, ToolApproval.t(), t()} | {:error, :approval_not_found | :no_pending_approval}
  def resolve_approval(
        %__MODULE__{
          phase: {:active, activity, %ToolApproval{} = approval, error}
        } = execution,
        approval_id,
        decision
      )
      when is_binary(approval_id) and
             decision in [:approve, :approve_session, :approve_turn, :reject] do
    resolve_matching_approval(execution, activity, approval, error, approval_id, decision)
  end

  def resolve_approval(%__MODULE__{}, _approval_id, _decision),
    do: {:error, :no_pending_approval}

  @doc "Records a trusted approval, or rejects it outside an admitted turn."
  @spec auto_approve(t(), Event.ToolApproval.t(), trust_scope()) ::
          {:approved, ToolApproval.t(), t()} | {:rejected, ToolApproval.t()}
  def auto_approve(
        %__MODULE__{phase: :idle},
        %Event.ToolApproval{} = event,
        _scope
      ),
      do: {:rejected, approval_from_event(event)}

  def auto_approve(
        %__MODULE__{phase: {:failure, _message}},
        %Event.ToolApproval{} = event,
        _scope
      ),
      do: {:rejected, approval_from_event(event)}

  def auto_approve(%__MODULE__{} = execution, %Event.ToolApproval{} = event, scope)
      when scope in [:session, :turn] do
    next = %{
      execution
      | pending_auto_approvals:
          Map.put(execution.pending_auto_approvals, event.tool_call_id, scope)
    }

    {:approved, approval_from_event(event), next}
  end

  @doc "Starts one tool and records its stable identity."
  @spec tool_started(t(), Event.ToolStart.t()) ::
          {:ok, trust_scope() | nil, t()} | {:error, :invalid_phase | :tool_already_active}
  def tool_started(
        %__MODULE__{
          phase: {:active, {:tool_execution, tools}, approval, _error}
        } = execution,
        %Event.ToolStart{} = event
      ),
      do: start_tool(execution, tools, approval, event)

  def tool_started(
        %__MODULE__{phase: {:active, _activity, approval, _error}} = execution,
        %Event.ToolStart{} = event
      ),
      do: start_tool(execution, [], approval, event)

  def tool_started(%__MODULE__{}, %Event.ToolStart{}),
    do: {:error, :invalid_phase}

  @doc "Completes one matching active tool and rejects stale or duplicate completions."
  @spec tool_completed(t(), Event.ToolEnd.t()) ::
          {:ok, t()} | {:error, :tool_not_active}
  def tool_completed(
        %__MODULE__{
          phase: {:active, {:tool_execution, tools}, approval, error}
        } = execution,
        %Event.ToolEnd{} = event
      ) do
    case List.keytake(tools, event.tool_call_id, 0) do
      {{_id, _name}, remaining} ->
        next = %{
          execution
          | phase: {:active, completed_tool_activity(remaining), approval, error},
            pending_auto_approvals:
              Map.delete(execution.pending_auto_approvals, event.tool_call_id)
        }

        {:ok, next}

      nil ->
        {:error, :tool_not_active}
    end
  end

  def tool_completed(%__MODULE__{}, %Event.ToolEnd{}),
    do: {:error, :tool_not_active}

  @doc "Admits a prompt by starting an inactive turn or queueing behind an active turn."
  @spec admit_prompt(t(), prompt_kind(), content()) :: prompt_admission()
  def admit_prompt(
        %__MODULE__{phase: {:active, _activity, _approval, _error}} = execution,
        kind,
        content
      )
      when kind in [:steering, :follow_up] do
    queue_prompt(execution, kind, content)
  end

  def admit_prompt(%__MODULE__{} = execution, kind, _content)
      when kind in [:steering, :follow_up] do
    {:ok, next} = begin_turn(execution)
    {:send_now, next}
  end

  @doc "Recognizes an original admission before checking the current queue fence or turn."
  @spec queued_submission(t(), pos_integer(), String.t()) ::
          {:queued, queue_receipt()} | :new | {:error, :queue_submission_stale}
  def queued_submission(%__MODULE__{} = execution, expected, submission_id) do
    case List.keyfind(execution.queue_receipts, submission_id, 1) do
      {^expected, ^submission_id, _kind, _revision} = receipt -> {:queued, receipt}
      nil when expected == execution.next_prompt_id -> :new
      _old -> {:error, :queue_submission_stale}
    end
  end

  @doc "Queues one exact active-turn submission and retains its original receipt."
  @spec admit_queued_submission(
          t(),
          prompt_kind(),
          content(),
          pos_integer(),
          {String.t(), pos_integer()},
          [DraftSnapshot.attachment()],
          String.t() | nil
        ) ::
          {:ok, queue_receipt(), t()}
          | {:queued, queue_receipt()}
          | {:error,
             :queue_submission_stale
             | :queue_receipts_full
             | :prompt_queue_full
             | :turn_not_active}
  def admit_queued_submission(
        %__MODULE__{} = execution,
        kind,
        content,
        expected,
        {submission_id, committed_revision},
        attachments \\ [],
        source \\ nil
      ) do
    with :new <- queued_submission(execution, expected, submission_id),
         true <- active?(execution) || {:error, :turn_not_active},
         :ok <- available_receipt_slot(execution.queue_receipts),
         {:queued, queued} <- queue_prompt(execution, kind, content, attachments, source) do
      receipt = {expected, submission_id, kind, committed_revision}
      {:ok, receipt, %{queued | queue_receipts: [receipt | queued.queue_receipts]}}
    end
  end

  @spec available_receipt_slot([queue_receipt()]) :: :ok | {:error, :queue_receipts_full}
  defp available_receipt_slot(receipts) do
    if Enum.count_until(receipts, @max_queue_receipts) == @max_queue_receipts,
      do: {:error, :queue_receipts_full},
      else: :ok
  end

  @doc "Retires only a receipt the original caller confirmed it received."
  @spec confirm_queue_receipt(t(), queue_receipt()) :: {:ok, t()} | :unchanged
  def confirm_queue_receipt(%__MODULE__{} = execution, {id, _, _, _} = receipt) do
    case List.keytake(execution.queue_receipts, id, 0) do
      {^receipt, remaining} -> {:ok, %{execution | queue_receipts: remaining}}
      _other -> :unchanged
    end
  end

  @type queued_edit :: :remove | {:replace_text, String.t()}
  @type queued_edit_error ::
          :already_consumed
          | :queued_input_not_found
          | :stale_queue_revision
          | :prompt_queue_full
          | :invalid_queue_text

  @doc "Changes a single pending entry at the displayed revision without moving other inputs."
  @spec change_queued_input(t(), pos_integer(), pos_integer(), queued_edit()) ::
          {:ok, t()} | {:error, queued_edit_error()}
  def change_queued_input(%__MODULE__{} = execution, id, revision, operation) do
    with {:ok, field, queue, entry} <- find_pending_entry(execution, id),
         {:ok, updated} <- change_queue_entry(queue, entry, revision, operation),
         next = %{execution | field => updated},
         true <- pending_size_allowed?(next) || {:error, :prompt_queue_full} do
      {:ok, next}
    end
  end

  @spec find_pending_entry(t(), pos_integer()) ::
          {:ok, :steering_queue | :follow_up_queue, [queued_input()], queued_input()}
          | {:error, :already_consumed | :queued_input_not_found}
  defp find_pending_entry(execution, id) do
    case List.keyfind(execution.steering_queue, id, 0) do
      nil -> find_follow_up_entry(execution, id)
      entry -> {:ok, :steering_queue, execution.steering_queue, entry}
    end
  end

  @spec find_follow_up_entry(t(), pos_integer()) ::
          {:ok, :follow_up_queue, [queued_input()], queued_input()}
          | {:error, :already_consumed | :queued_input_not_found}
  defp find_follow_up_entry(execution, id) do
    case List.keyfind(execution.follow_up_queue, id, 0) do
      nil when id < execution.next_prompt_id -> {:error, :already_consumed}
      nil -> {:error, :queued_input_not_found}
      entry -> {:ok, :follow_up_queue, execution.follow_up_queue, entry}
    end
  end

  @spec change_queue_entry([queued_input()], queued_input(), pos_integer(), queued_edit()) ::
          {:ok, [queued_input()]} | {:error, :stale_queue_revision | :invalid_queue_text}
  defp change_queue_entry(queue, {id, revision, _, _, _}, revision, :remove),
    do: {:ok, List.keydelete(queue, id, 0)}

  defp change_queue_entry(
         queue,
         {id, revision, content, refs, source},
         revision,
         {:replace_text, text}
       ) do
    if byte_size(text) <= @max_pending_bytes and String.valid?(text) do
      editable = if is_binary(source), do: text, else: nil
      entry = {id, revision + 1, replace_queued_text(content, text), refs, editable}
      {:ok, List.keyreplace(queue, id, 0, entry)}
    else
      {:error, :invalid_queue_text}
    end
  end

  defp change_queue_entry(_queue, _entry, _revision, _operation),
    do: {:error, :stale_queue_revision}

  @spec replace_queued_text(content(), String.t()) :: content()
  defp replace_queued_text(content, text) when is_binary(content), do: text

  defp replace_queued_text([%ReqLLM.Message.ContentPart{type: :text} = head | rest], text),
    do: [%{head | text: text} | rest]

  defp replace_queued_text(parts, text), do: [ReqLLM.Message.ContentPart.text(text) | parts]

  @doc "Transfers pending inputs to a candidate draft without dropping captured attachments or non-text input."
  @spec recall_draft(t(), DraftSnapshot.t() | nil) ::
          {:ok, DraftSnapshot.t(), t()} | {:error, term()}
  def recall_draft(%__MODULE__{steering_queue: [], follow_up_queue: []}, _draft),
    do: {:error, :no_pending_inputs}

  def recall_draft(%__MODULE__{} = execution, draft) do
    with {:ok, text, attachments} <-
           recall_inputs(execution.steering_queue ++ execution.follow_up_queue, [], []),
         {:ok, restored} <- DraftSnapshot.prepend_recalled(draft, text, attachments) do
      {:ok, restored, clear_queue_values(execution)}
    end
  end

  @spec recall_inputs([queued_input()], [iodata()], [[DraftSnapshot.attachment()]]) ::
          {:ok, iodata(), [DraftSnapshot.attachment()]} | {:error, :queue_content_not_recallable}
  defp recall_inputs([], text, attachments),
    do:
      {:ok, text |> Enum.reverse() |> Enum.intersperse("\n\n"),
       Enum.concat(Enum.reverse(attachments))}

  defp recall_inputs([{_id, _revision, content, attachments, source} | rest], text, retained) do
    with {:ok, editable} <- recall_editable_text(source, content, attachments) do
      text = if IO.iodata_length(editable) == 0, do: text, else: [editable | text]
      recall_inputs(rest, text, [attachments | retained])
    end
  end

  @spec recall_editable_text(String.t() | nil, content(), [DraftSnapshot.attachment()]) ::
          {:ok, iodata()} | {:error, :queue_content_not_recallable}
  defp recall_editable_text(source, _content, _attachments) when is_binary(source),
    do: {:ok, source}

  defp recall_editable_text(nil, content, attachments),
    do: recall_editable_text(content, attachments)

  @spec recall_editable_text(content(), [DraftSnapshot.attachment()]) ::
          {:ok, iodata()} | {:error, :queue_content_not_recallable}
  defp recall_editable_text(text, []) when is_binary(text), do: {:ok, text}

  defp recall_editable_text(parts, attachments) when is_list(parts) do
    editable = if attachments == [], do: parts, else: Enum.drop(parts, -length(attachments))

    Enum.reduce_while(editable, {:ok, []}, fn
      %ReqLLM.Message.ContentPart{type: :text, text: text}, {:ok, acc} when is_binary(text) ->
        {:cont, {:ok, [text | acc]}}

      _part, _acc ->
        {:halt, {:error, :queue_content_not_recallable}}
    end)
    |> recalled_text()
  end

  defp recall_editable_text(_content, _attachments), do: {:error, :queue_content_not_recallable}

  @spec recalled_text({:ok, [binary()]} | {:error, :queue_content_not_recallable}) ::
          {:ok, iodata()} | {:error, :queue_content_not_recallable}
  defp recalled_text({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp recalled_text({:error, _reason} = error), do: error

  @doc "Dequeues steering prompts without changing follow-up admission."
  @spec dequeue_steering(t()) :: {[content()], t()}
  def dequeue_steering(%__MODULE__{} = execution) do
    {prompt_contents(execution.steering_queue), %{execution | steering_queue: []}}
  end

  @doc "Returns and clears both prompt queues."
  @spec recall_queues(t()) :: {{[content()], [content()]}, t()}
  def recall_queues(%__MODULE__{} = execution),
    do: {queues(execution), clear_queue_values(execution)}

  @doc "Clears both prompt queues."
  @spec clear_queues(t()) :: t()
  def clear_queues(%__MODULE__{} = execution), do: clear_queue_values(execution)

  @doc "Returns steering and follow-up queues in FIFO order."
  @spec queues(t()) :: {[content()], [content()]}
  def queues(%__MODULE__{} = execution),
    do: {prompt_contents(execution.steering_queue), prompt_contents(execution.follow_up_queue)}

  @doc "Captures the durable input queues without session trust or runtime phase."
  @spec pending_inputs(t()) :: pending_inputs()
  def pending_inputs(%__MODULE__{} = execution),
    do: {
      execution.next_prompt_id,
      execution.steering_queue,
      execution.follow_up_queue,
      execution.queue_receipts
    }

  @doc "Restores admitted inputs in an idle session without starting a provider request."
  @spec restore_pending_inputs(pending_inputs()) :: t()
  def restore_pending_inputs({next_id, steering, follow_up, receipts}),
    do: %__MODULE__{
      next_prompt_id: next_id,
      steering_queue: steering,
      follow_up_queue: follow_up,
      queue_receipts: receipts
    }

  @doc "Validates a restored queue's bounded entries and non-reusable IDs."
  @spec valid_pending_inputs?(term()) :: boolean()
  def valid_pending_inputs?({next, steering, follow_up, receipts})
      when is_integer(next) and next > 0 and is_list(steering) and is_list(follow_up) and
             is_list(receipts) do
    with true <- length(steering) + length(follow_up) <= @max_pending_inputs,
         true <- :erlang.external_size({steering, follow_up}) <= @max_pending_bytes,
         {:ok, seen} <- validate_entries(steering, 0, next, %{}),
         {:ok, _seen} <- validate_entries(follow_up, 0, next, seen),
         true <- length(receipts) <= @max_queue_receipts + @max_pending_inputs,
         true <- valid_queue_receipts?(receipts, next, %{}) do
      true
    else
      _invalid -> false
    end
  end

  def valid_pending_inputs?(_invalid), do: false

  @spec valid_queue_receipts?(list(), pos_integer(), %{optional(String.t()) => true}) :: boolean()
  defp valid_queue_receipts?([], _next, _seen), do: true

  defp valid_queue_receipts?([{id, submission_id, kind, revision} | rest], next, seen)
       when is_integer(id) and id > 0 and id < next and is_binary(submission_id) and
              byte_size(submission_id) == 24 and kind in [:steering, :follow_up] and
              is_integer(revision) and revision > 0 do
    not is_map_key(seen, submission_id) and
      valid_queue_receipts?(rest, id, Map.put(seen, submission_id, true))
  end

  defp valid_queue_receipts?(_invalid, _next, _seen), do: false

  @spec validate_entries(list(), non_neg_integer(), pos_integer(), %{
          optional(pos_integer()) => true
        }) ::
          {:ok, %{optional(pos_integer()) => true}} | :invalid
  defp validate_entries([], _previous, _next, seen), do: {:ok, seen}

  defp validate_entries(
         [{id, revision, content, attachments, source} | rest],
         previous,
         next,
         seen
       )
       when is_integer(id) and id > previous and id < next and is_integer(revision) and
              revision > 0 and is_list(attachments) do
    if valid_queue_content?(content) and valid_queue_attachments?(attachments) and
         (is_nil(source) or (is_binary(source) and String.valid?(source))) and
         not is_map_key(seen, id) do
      validate_entries(rest, id, next, Map.put(seen, id, true))
    else
      :invalid
    end
  end

  defp validate_entries(_invalid, _previous, _next, _seen), do: :invalid

  @spec valid_queue_attachments?([term()]) :: boolean()
  defp valid_queue_attachments?(attachments) do
    Enum.all?(attachments, &match?({_, _, _, _, {:snapshot, %Reference{}}}, &1))
  end

  @spec valid_queue_content?(term()) :: boolean()
  defp valid_queue_content?(text) when is_binary(text), do: String.valid?(text)

  defp valid_queue_content?(parts) when is_list(parts),
    do: Enum.all?(parts, &is_struct(&1, ReqLLM.Message.ContentPart))

  defp valid_queue_content?(_invalid), do: false

  @spec prompt_contents([queued_input()]) :: [content()]
  defp prompt_contents(entries),
    do: Enum.map(entries, fn {_id, _revision, content, _references, _source} -> content end)

  @doc "Switches to plan mode while preserving the runtime phase."
  @spec enter_plan(t()) :: t()
  def enter_plan(%__MODULE__{} = execution) do
    execution
    |> clear_approval()
    |> transition_mode(:plan)
  end

  @doc "Switches from plan mode to execution mode."
  @spec enter_exec(t()) :: {:changed, t()} | :unchanged
  def enter_exec(%__MODULE__{mode: :exec}), do: :unchanged

  def enter_exec(%__MODULE__{mode: :plan} = execution),
    do: {:changed, transition_mode(execution, :exec)}

  @doc "Aborts provider and tool work before returning to an inactive phase."
  @spec abort(t()) :: t()
  def abort(%__MODULE__{} = execution) do
    %{
      execution
      | phase: :idle,
        trust_levels: drop_turn_trust(execution.trust_levels),
        pending_auto_approvals: %{}
    }
  end

  @doc "Moves any runtime phase into failure and clears turn-owned active resources."
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{} = execution, message) when is_binary(message) do
    %{
      execution
      | phase: {:failure, message},
        trust_levels: drop_turn_trust(execution.trust_levels),
        pending_auto_approvals: %{}
    }
  end

  @doc "Records a provider-reported error without discarding active turn work."
  @spec report_error(t(), String.t()) :: t()
  def report_error(
        %__MODULE__{phase: {:active, activity, approval, _old_error}} = execution,
        message
      )
      when is_binary(message),
      do: %{execution | phase: {:active, activity, approval, message}}

  def report_error(%__MODULE__{} = execution, message) when is_binary(message),
    do: fail(execution, message)

  @doc "Updates the current provider failure presentation without changing its phase."
  @spec update_failure(t(), String.t()) :: {:ok, t()} | {:error, :invalid_phase}
  def update_failure(%__MODULE__{phase: {:failure, _old}} = execution, message)
      when is_binary(message),
      do: {:ok, %{execution | phase: {:failure, message}}}

  def update_failure(%__MODULE__{}, _message),
    do: {:error, :invalid_phase}

  @doc "Clears a provider failure after provider recovery."
  @spec recover(t()) :: {:changed, t()} | :unchanged
  def recover(%__MODULE__{phase: {:failure, _message}} = execution),
    do: {:changed, %{execution | phase: :idle}}

  def recover(%__MODULE__{}), do: :unchanged

  @doc "Moves an admitted turn into completion."
  @spec begin_completion(t()) :: {:ok, t()} | {:error, :invalid_phase}
  def begin_completion(%__MODULE__{phase: :idle}),
    do: {:error, :invalid_phase}

  def begin_completion(%__MODULE__{} = execution),
    do: {:ok, activate(execution, :completion)}

  @doc "Finishes completion, clearing turn trust before admitting queued work."
  @spec finish_completion(t()) ::
          {:idle, t()}
          | {:send_next, [content(), ...], t()}
          | {:error, :invalid_phase}
  def finish_completion(%__MODULE__{phase: {:active, :completion, nil, _error}} = execution) do
    {steering, follow_up} = queues(execution)
    pending = steering ++ follow_up

    next = %{
      execution
      | trust_levels: drop_turn_trust(execution.trust_levels),
        pending_auto_approvals: %{},
        steering_queue: [],
        follow_up_queue: []
    }

    finish_completion_result(next, pending)
  end

  def finish_completion(%__MODULE__{}),
    do: {:error, :invalid_phase}

  @doc "Returns a failed queued-send transition to idle without restoring consumed entries."
  @spec queued_send_failed(t()) :: {:ok, t()} | {:error, :invalid_phase}
  def queued_send_failed(%__MODULE__{phase: {:active, :starting, nil, _error}} = execution),
    do: {:ok, %{execution | phase: :idle}}

  def queued_send_failed(%__MODULE__{}),
    do: {:error, :invalid_phase}

  @doc "Resets every turn resource for a fresh session."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{}), do: new()

  @doc "Restores an idle execution value after live work is cleaned up."
  @spec restore(t()) :: t()
  def restore(%__MODULE__{}), do: new()

  @doc "Adds or replaces one tool trust decision."
  @spec put_trust(t(), String.t(), trust_scope()) :: t()
  def put_trust(%__MODULE__{} = execution, name, scope)
      when is_binary(name) and scope in [:session, :turn] do
    %{execution | trust_levels: Map.put(execution.trust_levels, name, scope)}
  end

  @doc "Removes one or all tool trust decisions."
  @spec revoke_trust(t(), String.t() | :all) :: t()
  def revoke_trust(%__MODULE__{} = execution, :all), do: %{execution | trust_levels: %{}}

  def revoke_trust(%__MODULE__{} = execution, name) when is_binary(name),
    do: %{execution | trust_levels: Map.delete(execution.trust_levels, name)}

  @doc "Returns all current tool trust decisions."
  @spec trust_levels(t()) :: %{String.t() => trust_scope()}
  def trust_levels(%__MODULE__{trust_levels: trust_levels}), do: trust_levels

  @doc "Returns the matching trust scope for one provider approval event."
  @spec trusted_scope(t(), Event.ToolApproval.t()) :: trust_scope() | nil
  def trusted_scope(%__MODULE__{trust_levels: trust_levels}, %Event.ToolApproval{} = event) do
    Map.get(trust_levels, trust_key(event.name, event.args)) || Map.get(trust_levels, event.name)
  end

  @doc "Validates and stores an edit boundary by absolute path."
  @spec set_boundary(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, String.t()}
  def set_boundary(%__MODULE__{} = execution, path, start_line, end_line)
      when is_binary(path) and is_integer(start_line) and is_integer(end_line) do
    case EditBoundary.new(start_line, end_line) do
      {:ok, boundary} ->
        abs_path = Path.expand(path)
        {:ok, %{execution | boundaries: Map.put(execution.boundaries, abs_path, boundary)}}

      {:error, _message} = error ->
        error
    end
  end

  @doc "Clears one edit boundary."
  @spec clear_boundary(t(), String.t()) :: t()
  def clear_boundary(%__MODULE__{} = execution, path) when is_binary(path) do
    %{execution | boundaries: Map.delete(execution.boundaries, Path.expand(path))}
  end

  @doc "Clears every edit boundary."
  @spec clear_boundaries(t()) :: t()
  def clear_boundaries(%__MODULE__{} = execution), do: %{execution | boundaries: %{}}

  @doc "Returns one edit boundary as its public line tuple."
  @spec boundary(t(), String.t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def boundary(%__MODULE__{} = execution, path) when is_binary(path) do
    case Map.get(execution.boundaries, Path.expand(path)) do
      nil -> nil
      %EditBoundary{start_line: start_line, end_line: end_line} -> {start_line, end_line}
    end
  end

  @doc "Returns true when turn state does not prevent detached-session reclamation."
  @spec reclaimable?(t()) :: boolean()
  def reclaimable?(%__MODULE__{} = execution) do
    not active?(execution) and execution.pending_auto_approvals == %{} and
      execution.steering_queue == [] and execution.follow_up_queue == []
  end

  @spec resolve_matching_approval(
          t(),
          activity(),
          ToolApproval.t(),
          String.t() | nil,
          String.t(),
          approval_decision()
        ) ::
          {:ok, ToolApproval.t(), t()} | {:error, :approval_not_found}
  defp resolve_matching_approval(
         _execution,
         _activity,
         approval,
         _error,
         approval_id,
         _decision
       )
       when approval.tool_call_id != approval_id,
       do: {:error, :approval_not_found}

  defp resolve_matching_approval(
         execution,
         activity,
         %ToolApproval{tool_call_id: approval_id} = approval,
         error,
         approval_id,
         decision
       ) do
    execution = maybe_put_decision_trust(execution, approval, decision)
    {:ok, approval, %{execution | phase: {:active, activity, nil, error}}}
  end

  @spec approval_from_event(Event.ToolApproval.t()) :: ToolApproval.t()
  defp approval_from_event(event) do
    ToolApproval.new(
      tool_call_id: event.tool_call_id,
      name: event.name,
      args: event.args,
      reply_to: event.reply_to
    )
  end

  @spec maybe_put_decision_trust(t(), ToolApproval.t(), approval_decision()) :: t()
  defp maybe_put_decision_trust(execution, approval, :approve_session),
    do: put_trust(execution, approval_trust_key(approval), :session)

  defp maybe_put_decision_trust(execution, approval, :approve_turn),
    do: put_trust(execution, approval_trust_key(approval), :turn)

  defp maybe_put_decision_trust(execution, _approval, _decision), do: execution

  @spec queue_prompt(
          t(),
          prompt_kind(),
          content(),
          [DraftSnapshot.attachment()],
          String.t() | nil
        ) ::
          prompt_admission()
  defp queue_prompt(%__MODULE__{} = execution, kind, content, attachments \\ [], source \\ nil) do
    source = if source == content, do: nil, else: source
    entry = {execution.next_prompt_id, 1, content, attachments, source}
    candidate = put_queued_input(execution, kind, entry)

    if pending_size_allowed?(candidate) do
      {:queued, %{candidate | next_prompt_id: execution.next_prompt_id + 1}}
    else
      {:error, :prompt_queue_full}
    end
  end

  @spec pending_size_allowed?(t()) :: boolean()
  defp pending_size_allowed?(%__MODULE__{steering_queue: steering, follow_up_queue: follow_up}) do
    length(steering) + length(follow_up) <= @max_pending_inputs and
      :erlang.external_size({steering, follow_up}) <= @max_pending_bytes
  end

  @spec put_queued_input(t(), prompt_kind(), queued_input()) :: t()
  defp put_queued_input(execution, :steering, entry),
    do: %{execution | steering_queue: List.insert_at(execution.steering_queue, -1, entry)}

  defp put_queued_input(execution, :follow_up, entry),
    do: %{execution | follow_up_queue: List.insert_at(execution.follow_up_queue, -1, entry)}

  @spec clear_approval(t()) :: t()
  defp clear_approval(
         %__MODULE__{phase: {:active, activity, %ToolApproval{}, error}} = execution
       ),
       do: %{execution | phase: {:active, activity, nil, error}}

  defp clear_approval(%__MODULE__{} = execution), do: execution

  @spec start_tool(t(), [active_tool()], interaction(), Event.ToolStart.t()) ::
          {:ok, trust_scope() | nil, t()} | {:error, :tool_already_active}
  defp start_tool(execution, tools, approval, event) do
    if List.keymember?(tools, event.tool_call_id, 0) do
      {:error, :tool_already_active}
    else
      {scope, pending_auto_approvals} =
        Map.pop(execution.pending_auto_approvals, event.tool_call_id)

      # Active tool calls are bounded by provider concurrency and exposed in start order.
      # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
      active_tools = tools ++ [{event.tool_call_id, event.name}]

      next = %{
        execution
        | phase: {:active, {:tool_execution, active_tools}, approval, nil},
          pending_auto_approvals: pending_auto_approvals
      }

      {:ok, scope, next}
    end
  end

  @spec activate(t(), activity()) :: t()
  defp activate(%__MODULE__{} = execution, activity),
    do: %{execution | phase: {:active, activity, nil, nil}}

  @spec completed_tool_activity([active_tool()]) ::
          :completion | {:tool_execution, [active_tool(), ...]}
  defp completed_tool_activity([]), do: :completion
  defp completed_tool_activity([_tool | _rest] = tools), do: {:tool_execution, tools}

  @spec activity_phase(activity()) :: :starting | :thinking | :tool_execution | :completion
  defp activity_phase(:starting), do: :starting
  defp activity_phase(:thinking), do: :thinking
  defp activity_phase(:completion), do: :completion
  defp activity_phase({:tool_execution, [_tool | _rest]}), do: :tool_execution

  @spec activity_status(activity()) :: :idle | :thinking | :tool_executing
  defp activity_status(:starting), do: :idle
  defp activity_status(:thinking), do: :thinking
  defp activity_status(:completion), do: :tool_executing
  defp activity_status({:tool_execution, [_tool | _rest]}), do: :tool_executing

  @spec transition_mode(t(), mode()) :: t()
  defp transition_mode(%__MODULE__{} = execution, mode), do: struct!(execution, mode: mode)

  @spec finish_completion_result(t(), [content()]) ::
          {:idle, t()} | {:send_next, [content(), ...], t()}
  defp finish_completion_result(next, []) do
    {:idle, %{next | phase: :idle}}
  end

  defp finish_completion_result(next, [_entry | _rest] = pending) do
    {:send_next, pending, activate(next, :starting)}
  end

  @spec clear_queue_values(t()) :: t()
  defp clear_queue_values(execution),
    do: %{execution | steering_queue: [], follow_up_queue: []}

  @spec drop_turn_trust(%{String.t() => trust_scope()}) :: %{String.t() => trust_scope()}
  defp drop_turn_trust(trust_levels),
    do: Map.reject(trust_levels, fn {_name, scope} -> scope == :turn end)

  @spec approval_trust_key(ToolApproval.t()) :: String.t()
  defp approval_trust_key(%ToolApproval{name: name, args: args}), do: trust_key(name, args)

  @spec trust_key(String.t(), map()) :: String.t()
  defp trust_key("shell", args) when is_map(args), do: shell_trust_key(args)

  defp trust_key("call_mcp_tool", args) when is_map(args),
    do: hashed_trust_key("call_mcp_tool", args)

  defp trust_key("list_mcp_tools", args) when is_map(args),
    do: hashed_trust_key("list_mcp_tools", args)

  defp trust_key("mcp_" <> _rest = name, args) when is_map(args), do: hashed_trust_key(name, args)
  defp trust_key(name, _args), do: name

  @spec shell_trust_key(map()) :: String.t()
  defp shell_trust_key(args) do
    string_args = Map.new(args, fn {key, value} -> {to_string(key), value} end)

    case Map.get(string_args, "command") do
      command when is_binary(command) -> "shell:#{command}"
      _other -> hashed_trust_key("shell", args)
    end
  end

  @spec hashed_trust_key(String.t(), map()) :: String.t()
  defp hashed_trust_key(name, args) do
    hash =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(args))
      |> Base.encode16(case: :lower)

    "#{name}:#{hash}"
  end
end

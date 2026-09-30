defmodule MingaAgent.Session.Continuation do
  @moduledoc """
  Session-owned lossless model continuation and request identity state.

  Display messages live in `MingaAgent.Session.Transcript`; this value contains
  only canonical ReqLLM request values. A provider receives an immutable
  `Request` and returns an `Outcome`. Only Session applies that outcome.
  """

  alias MingaAgent.Message, as: DisplayMessage
  alias MingaAgent.Session.Outcome
  alias MingaAgent.Session.Request
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @typedoc "Origin and continuation guarantee of the stored model history."
  @type provenance :: :lossless | :legacy_reconstructed

  @typedoc "Durable disposition of one provider-issued tool call."
  @type tool_call_status ::
          :pending | :admitted | {:completed, Message.t()}

  @typedoc "One ordered tool call in a provider-native assistant response."
  @type checkpoint_call :: %{
          tool_call_id: String.t(),
          name: String.t(),
          arguments: map(),
          status: tool_call_status()
        }

  @typedoc "Exact provider continuation captured before any tool effect is admitted."
  @type tool_checkpoint :: %{
          version: pos_integer(),
          checkpoint_id: String.t(),
          request_id: String.t(),
          messages: [Message.t()],
          calls: [checkpoint_call()]
        }

  @typedoc "Completed model boundary correlated to the last display entry it produced."
  @type boundary :: %{
          transcript_id: pos_integer(),
          message_count: non_neg_integer(),
          revision: non_neg_integer()
        }

  @typedoc "Lossless model history and boundary identities for one saved display branch."
  @type branch_snapshot :: %{messages: [Message.t()], boundaries: [boundary()]}

  @typedoc "Session-owned continuation state."
  @type t :: %__MODULE__{
          messages: [Message.t()],
          revision: non_neg_integer(),
          durable_revision: non_neg_integer(),
          active_request: Request.t() | nil,
          tool_checkpoint: tool_checkpoint() | nil,
          boundaries: [boundary()],
          branch_messages: %{String.t() => branch_snapshot()},
          provenance: provenance()
        }

  @enforce_keys [
    :messages,
    :revision,
    :durable_revision,
    :active_request,
    :tool_checkpoint,
    :boundaries,
    :branch_messages,
    :provenance
  ]
  defstruct @enforce_keys

  @doc "Creates an empty lossless continuation before the first provider request."
  @spec new() :: t()
  def new do
    %__MODULE__{
      messages: [],
      revision: 0,
      durable_revision: 0,
      active_request: nil,
      tool_checkpoint: nil,
      boundaries: [],
      branch_messages: %{},
      provenance: :lossless
    }
  end

  @doc "Begins one request by appending the exact user content to the last completed boundary."
  @spec begin_request(t(), String.t(), pos_integer(), String.t() | [ContentPart.t()]) ::
          {:ok, Request.t(), t()}
          | {:error,
             :request_active
             | :effect_reconciliation_required
             | :invalid_attachment
             | :invalid_message}
  def begin_request(%__MODULE__{tool_checkpoint: %{}}, _request_id, _turn_id, _content),
    do: {:error, :effect_reconciliation_required}

  def begin_request(%__MODULE__{active_request: %Request{}}, _request_id, _turn_id, _content),
    do: {:error, :request_active}

  def begin_request(%__MODULE__{} = continuation, request_id, turn_id, content) do
    user_message = Context.user(content)
    messages = Enum.concat(continuation.messages, [user_message])

    with :ok <- validate_messages(messages) do
      request = Request.new(request_id, turn_id, continuation.revision, messages)
      {:ok, request, %{continuation | active_request: request}}
    end
  end

  @doc "Returns whether an event belongs to the currently admitted request."
  @spec accepts?(t(), String.t()) :: boolean()
  def accepts?(%__MODULE__{active_request: %Request{request_id: request_id}}, request_id),
    do: true

  def accepts?(%__MODULE__{}, _request_id), do: false

  @doc "Applies an exact matching outcome once and records its display boundary."
  @spec complete(t(), Outcome.t(), pos_integer()) ::
          {:ok, t()}
          | {:error,
             :stale_outcome
             | :duplicate_outcome
             | :invalid_attachment
             | :invalid_message
             | :unresolved_tool_checkpoint
             | :invalid_checkpoint_progression}
  def complete(%__MODULE__{active_request: nil}, %Outcome{}, _transcript_id),
    do: {:error, :duplicate_outcome}

  def complete(
        %__MODULE__{active_request: %Request{} = request} = continuation,
        %Outcome{} = outcome,
        transcript_id
      )
      when is_integer(transcript_id) and transcript_id > 0 do
    if matching_outcome?(request, outcome) do
      revision = continuation.revision + 1

      with :ok <- validate_messages(outcome.messages),
           :ok <- validate_initial_request_prefix(outcome.messages, request.messages),
           :ok <- validate_outcome_checkpoint(continuation.tool_checkpoint, outcome.messages) do
        boundary = %{
          transcript_id: transcript_id,
          message_count: Enum.count(outcome.messages),
          revision: revision
        }

        {:ok,
         %{
           continuation
           | messages: outcome.messages,
             revision: revision,
             active_request: nil,
             tool_checkpoint: nil,
             boundaries: Enum.concat(continuation.boundaries, [boundary])
         }}
      end
    else
      {:error, :stale_outcome}
    end
  end

  @doc "Cancels the active request identity without discarding a durable effect checkpoint."
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = continuation), do: %{continuation | active_request: nil}

  @doc "Preserves the exact active request as the basis for a later continuation."
  @spec interrupt_request(t()) :: t()
  def interrupt_request(
        %__MODULE__{active_request: %Request{messages: messages, turn_id: turn_id}} =
          continuation
      ) do
    revision = continuation.revision + 1

    boundary = %{
      transcript_id: turn_id,
      message_count: length(messages),
      revision: revision
    }

    %{
      continuation
      | messages: messages,
        revision: revision,
        active_request: nil,
        boundaries: Enum.concat(continuation.boundaries, [boundary])
    }
  end

  def interrupt_request(%__MODULE__{} = continuation), do: continuation

  @doc "Marks the current completed boundary as durably committed."
  @spec mark_durable(t()) :: t()
  def mark_durable(%__MODULE__{} = continuation) do
    %{continuation | durable_revision: continuation.revision}
  end

  @doc "Returns whether the current completed boundary is durably resumable."
  @spec durable?(t()) :: boolean()
  def durable?(%__MODULE__{} = continuation),
    do: continuation.durable_revision == continuation.revision

  @doc "Starts a fresh logical conversation while preserving no prior request identity."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{}), do: new()

  @doc "Snapshots the original branch and selects the exact boundary for a display entry."
  @spec branch_at(t(), String.t(), pos_integer()) ::
          {:ok, t()} | {:error, :branch_not_resumable}
  def branch_at(%__MODULE__{} = continuation, branch_name, transcript_id)
      when is_binary(branch_name) and is_integer(transcript_id) and transcript_id > 0 do
    branch_snapshot = %{
      messages: continuation.messages,
      boundaries: continuation.boundaries
    }

    branch_messages = Map.put(continuation.branch_messages, branch_name, branch_snapshot)
    revision = continuation.revision + 1

    case matching_boundary(continuation.boundaries, transcript_id) do
      nil ->
        {:error, :branch_not_resumable}

      boundary ->
        {:ok,
         %{
           continuation
           | messages: Enum.take(continuation.messages, boundary.message_count),
             revision: revision,
             active_request: nil,
             tool_checkpoint: nil,
             boundaries:
               Enum.filter(continuation.boundaries, &(&1.revision <= boundary.revision)),
             branch_messages: branch_messages
         }}
    end
  end

  @doc "Restores the lossless model values captured for a named display branch."
  @spec switch_branch(t(), String.t()) :: {:ok, t()} | {:error, :branch_not_resumable}
  def switch_branch(%__MODULE__{} = continuation, branch_name) when is_binary(branch_name) do
    case Map.fetch(continuation.branch_messages, branch_name) do
      {:ok, %{messages: messages, boundaries: boundaries}} ->
        revision = continuation.revision + 1

        {:ok,
         %{
           continuation
           | messages: messages,
             revision: revision,
             active_request: nil,
             tool_checkpoint: nil,
             boundaries: boundaries
         }}

      :error ->
        {:error, :branch_not_resumable}
    end
  end

  @doc "Replaces the system prompt through the Session-owned conversation transition."
  @spec replace_system(t(), Message.t()) :: {:ok, t()} | {:error, :request_active}
  def replace_system(%__MODULE__{active_request: %Request{}}, _system_message),
    do: {:error, :request_active}

  def replace_system(
        %__MODULE__{messages: [%Message{role: :system} = system_message | _rest]} = continuation,
        system_message
      ),
      do: {:ok, continuation}

  def replace_system(%__MODULE__{} = continuation, %Message{role: :system} = system_message) do
    messages =
      case continuation.messages do
        [%Message{role: :system} | rest] -> [system_message | rest]
        messages -> [system_message | messages]
      end

    {:ok, %{continuation | messages: messages, revision: continuation.revision + 1}}
  end

  @doc "Installs provider-produced compacted messages as a new Session-owned boundary."
  @spec replace_messages(t(), [Message.t()]) ::
          {:ok, t()} | {:error, :request_active | :invalid_attachment | :invalid_message}
  def replace_messages(%__MODULE__{active_request: %Request{}}, _messages),
    do: {:error, :request_active}

  def replace_messages(%__MODULE__{} = continuation, messages) when is_list(messages) do
    with :ok <- validate_messages(messages) do
      revision = continuation.revision + 1

      boundaries =
        case Enum.reverse(continuation.boundaries) do
          [%{transcript_id: transcript_id} | _rest] ->
            [%{transcript_id: transcript_id, message_count: length(messages), revision: revision}]

          [] ->
            []
        end

      {:ok, %{continuation | messages: messages, revision: revision, boundaries: boundaries}}
    end
  end

  @doc "Appends losslessly converted display history and binds it to its final display entry."
  @spec seed_messages(t(), [Message.t()], pos_integer()) ::
          {:ok, t()}
          | {:error,
             :request_active
             | :effect_reconciliation_required
             | :invalid_attachment
             | :invalid_message}
  def seed_messages(
        %__MODULE__{active_request: %Request{}},
        _messages,
        _transcript_id
      ),
      do: {:error, :request_active}

  def seed_messages(%__MODULE__{tool_checkpoint: %{}}, _messages, _transcript_id),
    do: {:error, :effect_reconciliation_required}

  def seed_messages(%__MODULE__{} = continuation, messages, transcript_id)
      when is_list(messages) and is_integer(transcript_id) and transcript_id > 0 do
    with :ok <- validate_messages(messages) do
      revision = continuation.revision + 1
      messages = continuation.messages ++ messages

      boundary = %{
        transcript_id: transcript_id,
        message_count: length(messages),
        revision: revision
      }

      {:ok,
       %{
         continuation
         | messages: messages,
           revision: revision,
           boundaries: Enum.concat(continuation.boundaries, [boundary])
       }}
    end
  end

  @doc "Restores a persisted continuation without changing its recorded provenance."
  @spec restore(
          [Message.t()],
          non_neg_integer(),
          non_neg_integer(),
          [boundary()],
          %{String.t() => branch_snapshot()},
          provenance()
        ) :: {:ok, t()} | {:error, term()}
  @spec restore(
          [Message.t()],
          non_neg_integer(),
          non_neg_integer(),
          [boundary()],
          %{String.t() => branch_snapshot()},
          provenance(),
          tool_checkpoint() | nil,
          Request.t() | nil
        ) :: {:ok, t()} | {:error, term()}
  def restore(
        messages,
        revision,
        durable_revision,
        boundaries,
        branch_messages,
        provenance,
        tool_checkpoint \\ nil,
        active_request \\ nil
      )
      when is_list(messages) and is_integer(revision) and revision >= 0 and
             is_integer(durable_revision) and durable_revision >= 0 and is_list(boundaries) and
             is_map(branch_messages) and provenance in [:lossless, :legacy_reconstructed] do
    with :ok <- validate_messages(messages),
         :ok <- validate_boundaries(boundaries, length(messages), revision),
         true <- durable_revision <= revision or {:error, :invalid_durable_revision},
         :ok <- validate_branches(branch_messages),
         :ok <- validate_tool_checkpoint(tool_checkpoint),
         :ok <- validate_active_request(active_request, revision, messages, tool_checkpoint) do
      {:ok,
       %__MODULE__{
         messages: messages,
         revision: revision,
         durable_revision: durable_revision,
         active_request: active_request,
         tool_checkpoint: tool_checkpoint,
         boundaries: boundaries,
         branch_messages: branch_messages,
         provenance: provenance
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec validate_active_request(
          Request.t() | nil,
          non_neg_integer(),
          [Message.t()],
          tool_checkpoint() | nil
        ) :: :ok | {:error, term()}
  defp validate_active_request(nil, _revision, _messages, nil), do: :ok

  defp validate_active_request(nil, _revision, _messages, _checkpoint),
    do: {:error, :invalid_active_request}

  defp validate_active_request(%Request{} = request, revision, messages, checkpoint) do
    request_prefix? =
      request.conversation_revision == revision and
        length(request.messages) > length(messages) and
        Enum.take(request.messages, length(messages)) == messages

    checkpoint_matches? =
      is_nil(checkpoint) or
        (checkpoint.request_id == request.request_id and
           length(checkpoint.messages) > length(request.messages) and
           Enum.take(checkpoint.messages, length(request.messages)) == request.messages)

    if request.version == 1 and request.request_id != "" and request.turn_id > 0 and
         request_prefix? and checkpoint_matches? and
         validate_messages(request.messages) == :ok do
      :ok
    else
      {:error, :invalid_active_request}
    end
  end

  defp validate_active_request(_request, _revision, _messages, _checkpoint),
    do: {:error, :invalid_active_request}

  @doc "Builds an explicitly lossy portable history from an old display-only record."
  @spec import_legacy([DisplayMessage.t()]) :: t()
  def import_legacy(display_messages) when is_list(display_messages) do
    messages =
      Enum.flat_map(display_messages, fn
        {:user, text} when is_binary(text) -> [Context.user(text)]
        {:user, text, _unrecoverable_attachments} when is_binary(text) -> [Context.user(text)]
        {:assistant, text} when is_binary(text) -> [Context.assistant(text)]
        _other -> []
      end)

    %__MODULE__{
      messages: messages,
      revision: 0,
      durable_revision: 0,
      active_request: nil,
      tool_checkpoint: nil,
      boundaries: [],
      branch_messages: %{},
      provenance: :legacy_reconstructed
    }
  end

  @doc "Captures an exact assistant tool-call group before any call can be admitted."
  @spec checkpoint_tool_group(t(), String.t(), [Message.t()], [map()]) ::
          {:ok, String.t(), t()} | {:error, term()}
  def checkpoint_tool_group(
        %__MODULE__{active_request: %Request{request_id: request_id}} = continuation,
        request_id,
        messages,
        calls
      )
      when is_list(messages) and is_list(calls) and calls != [] do
    with :ok <- validate_messages(messages),
         :ok <- validate_checkpoint_calls(calls),
         :ok <- validate_checkpoint_progression(continuation, messages) do
      checkpoint_id = checkpoint_id(request_id, messages, calls)

      checkpoint = %{
        version: 1,
        checkpoint_id: checkpoint_id,
        request_id: request_id,
        messages: messages,
        calls:
          Enum.map(calls, fn call ->
            %{
              tool_call_id: call.tool_call_id,
              name: call.name,
              arguments: call.arguments,
              status: :pending
            }
          end)
      }

      {:ok, checkpoint_id, %{continuation | tool_checkpoint: checkpoint}}
    end
  end

  def checkpoint_tool_group(%__MODULE__{}, _request_id, _messages, _calls),
    do: {:error, :stale_request}

  @doc "Durably grants the only executable token for one checkpointed tool call."
  @spec admit_tool_effect(t(), String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, t()} | {:error, term()}
  def admit_tool_effect(
        %__MODULE__{tool_checkpoint: checkpoint} = continuation,
        request_id,
        checkpoint_id,
        tool_call_id,
        name,
        arguments
      )
      when is_map(checkpoint) do
    with true <- checkpoint.request_id == request_id or {:error, :stale_request},
         true <- checkpoint.checkpoint_id == checkpoint_id or {:error, :stale_checkpoint},
         {:ok, call_index, call} <- find_checkpoint_call(checkpoint.calls, tool_call_id),
         true <-
           (call.name == name and call.arguments == arguments) or
             {:error, :tool_call_identity_mismatch},
         :pending <- call.status do
      calls = List.replace_at(checkpoint.calls, call_index, %{call | status: :admitted})
      {:ok, %{continuation | tool_checkpoint: %{checkpoint | calls: calls}}}
    else
      :admitted -> {:error, :duplicate_admission}
      {:completed, _message} -> {:error, :duplicate_admission}
      {:error, _reason} = error -> error
    end
  end

  def admit_tool_effect(%__MODULE__{}, _request_id, _checkpoint_id, _tool_call_id, _name, _args),
    do: {:error, :missing_tool_checkpoint}

  @doc "Records the exact terminal tool-result message against its original call identity."
  @spec complete_tool_effect(t(), String.t(), String.t(), String.t(), Message.t()) ::
          {:ok, t()} | {:error, term()}
  def complete_tool_effect(
        %__MODULE__{tool_checkpoint: checkpoint} = continuation,
        request_id,
        checkpoint_id,
        tool_call_id,
        %Message{} = result_message
      )
      when is_map(checkpoint) do
    with true <- checkpoint.request_id == request_id or {:error, :stale_request},
         true <- checkpoint.checkpoint_id == checkpoint_id or {:error, :stale_checkpoint},
         {:ok, call_index, call} <- find_checkpoint_call(checkpoint.calls, tool_call_id),
         :ok <- validate_tool_result_identity(call, tool_call_id, result_message) do
      case call.status do
        {:completed, ^result_message} ->
          {:ok, continuation}

        {:completed, _different_message} ->
          {:error, :conflicting_tool_outcome}

        status when status in [:pending, :admitted] ->
          calls =
            List.replace_at(checkpoint.calls, call_index, %{
              call
              | status: {:completed, result_message}
            })

          {:ok, %{continuation | tool_checkpoint: %{checkpoint | calls: calls}}}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  def complete_tool_effect(
        %__MODULE__{},
        _request_id,
        _checkpoint_id,
        _tool_call_id,
        %Message{}
      ),
      do: {:error, :missing_tool_checkpoint}

  @spec validate_tool_result_identity(checkpoint_call(), String.t(), Message.t()) ::
          :ok | {:error, :tool_result_identity_mismatch}
  defp validate_tool_result_identity(
         %{tool_call_id: tool_call_id},
         tool_call_id,
         %Message{
           role: :tool,
           tool_call_id: tool_call_id,
           content: content
         }
       ) do
    if valid_tool_result_content?(content),
      do: :ok,
      else: {:error, :tool_result_identity_mismatch}
  end

  defp validate_tool_result_identity(_call, _tool_call_id, _result_message),
    do: {:error, :tool_result_identity_mismatch}

  @spec valid_tool_result_content?(term()) :: boolean()
  defp valid_tool_result_content?(content) when is_binary(content), do: true

  defp valid_tool_result_content?(content) when is_list(content) do
    Enum.all?(content, &match?(%ContentPart{type: :text, text: text} when is_binary(text), &1))
  end

  defp valid_tool_result_content?(_content), do: false

  @doc "Turns an interrupted checkpoint into a safe exact continuation without replaying calls."
  @spec reconcile_interrupted(t(), pos_integer()) :: {t(), [map()]}
  def reconcile_interrupted(%__MODULE__{tool_checkpoint: nil} = continuation, _transcript_id),
    do: {continuation, []}

  def reconcile_interrupted(
        %__MODULE__{tool_checkpoint: checkpoint} = continuation,
        transcript_id
      )
      when is_integer(transcript_id) and transcript_id > 0 do
    {result_messages, reversed_reconciliation} =
      Enum.map_reduce(checkpoint.calls, [], fn call, statuses ->
        {message, status} = reconciliation_result(call)

        {message,
         [
           %{
             tool_call_id: call.tool_call_id,
             name: call.name,
             status: status,
             result_message: message
           }
           | statuses
         ]}
      end)

    reconciliation = Enum.reverse(reversed_reconciliation)
    revision = continuation.revision + 1

    boundary = %{
      transcript_id: transcript_id,
      message_count: length(checkpoint.messages) + length(result_messages),
      revision: revision
    }

    reconciled = %{
      continuation
      | messages: checkpoint.messages ++ result_messages,
        revision: revision,
        active_request: nil,
        tool_checkpoint: nil,
        boundaries: Enum.concat(continuation.boundaries, [boundary])
    }

    {reconciled, reconciliation}
  end

  @doc "Validates canonical ReqLLM message fields and required inline attachments."
  @spec validate_messages([Message.t()]) ::
          :ok | {:error, :invalid_message | :invalid_attachment}
  def validate_messages(messages) when is_list(messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case validate_message(message) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_message(term()) :: :ok | {:error, :invalid_message | :invalid_attachment}
  defp validate_message(%Message{} = message) do
    if valid_message_shape?(message) do
      validate_message_attachments(message)
    else
      {:error, :invalid_message}
    end
  end

  defp validate_message(_message), do: {:error, :invalid_message}

  defp validate_message_attachments(message) do
    if valid_message_attachments?(message), do: :ok, else: {:error, :invalid_attachment}
  end

  @spec valid_message_shape?(Message.t()) :: boolean()
  defp valid_message_shape?(%Message{
         role: role,
         content: content,
         name: name,
         tool_call_id: tool_call_id,
         tool_calls: tool_calls,
         metadata: metadata,
         reasoning_details: reasoning_details
       }) do
    role in [:user, :assistant, :system, :tool] and is_list(content) and
      (is_nil(name) or is_binary(name)) and
      (is_nil(tool_call_id) or is_binary(tool_call_id)) and
      (is_nil(tool_calls) or is_list(tool_calls)) and is_map(metadata) and
      (is_nil(reasoning_details) or is_list(reasoning_details))
  end

  @spec matching_outcome?(Request.t(), Outcome.t()) :: boolean()
  defp matching_outcome?(request, outcome) do
    request.request_id == outcome.request_id and request.turn_id == outcome.turn_id and
      request.conversation_revision == outcome.conversation_revision and outcome.version == 1
  end

  @spec matching_boundary([boundary()], pos_integer()) :: boundary() | nil
  defp matching_boundary(boundaries, transcript_id) do
    Enum.find(boundaries, &(&1.transcript_id == transcript_id))
  end

  @spec validate_boundaries([boundary()], non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :invalid_continuation_boundaries}
  defp validate_boundaries(boundaries, message_count, revision) do
    Enum.reduce_while(boundaries, {:ok, nil}, fn
      %{transcript_id: _id, message_count: _count, revision: _boundary_revision} = boundary,
      {:ok, previous} ->
        if valid_boundary?(boundary, message_count, revision) and
             ordered_boundary?(boundary, previous),
           do: {:cont, {:ok, boundary}},
           else: {:halt, {:error, :invalid_continuation_boundaries}}

      _boundary, _acc ->
        {:halt, {:error, :invalid_continuation_boundaries}}
    end)
    |> case do
      {:ok, _last} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec valid_boundary?(boundary(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp valid_boundary?(
         %{transcript_id: id, message_count: count, revision: boundary_revision},
         message_count,
         revision
       ) do
    is_integer(id) and id > 0 and is_integer(count) and count > 0 and
      count <= message_count and is_integer(boundary_revision) and boundary_revision > 0 and
      boundary_revision <= revision
  end

  @spec ordered_boundary?(boundary(), boundary() | nil) :: boolean()
  defp ordered_boundary?(_boundary, nil), do: true

  defp ordered_boundary?(boundary, previous) do
    boundary.transcript_id >= previous.transcript_id and
      boundary.message_count > previous.message_count and
      boundary.revision > previous.revision
  end

  @spec validate_branches(%{String.t() => branch_snapshot()}) ::
          :ok | {:error, :invalid_message | :invalid_attachment | :invalid_continuation_branches}
  defp validate_branches(branches) do
    Enum.reduce_while(branches, :ok, fn
      {_name, %{messages: messages, boundaries: boundaries}}, :ok
      when is_list(messages) and is_list(boundaries) ->
        case validate_branch_snapshot(messages, boundaries) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, :ok ->
        {:halt, {:error, :invalid_continuation_branches}}
    end)
  end

  @spec validate_branch_snapshot([Message.t()], [boundary()]) ::
          :ok | {:error, :invalid_message | :invalid_attachment | :invalid_continuation_branches}
  defp validate_branch_snapshot(messages, boundaries) do
    with :ok <- validate_messages(messages),
         true <- valid_branch_boundaries?(boundaries, length(messages)) do
      :ok
    else
      false -> {:error, :invalid_continuation_branches}
      {:error, _reason} = error -> error
    end
  end

  @spec valid_branch_boundaries?([boundary()], non_neg_integer()) :: boolean()
  defp valid_branch_boundaries?(boundaries, message_count) do
    revision =
      Enum.reduce(boundaries, 0, fn
        %{revision: boundary_revision}, max_revision when is_integer(boundary_revision) ->
          max(boundary_revision, max_revision)

        _boundary, max_revision ->
          max_revision
      end)

    validate_boundaries(boundaries, message_count, revision) == :ok
  end

  @spec validate_tool_checkpoint(tool_checkpoint() | nil) :: :ok | {:error, term()}
  defp validate_tool_checkpoint(nil), do: :ok

  defp validate_tool_checkpoint(%{
         version: 1,
         checkpoint_id: checkpoint_id,
         request_id: request_id,
         messages: messages,
         calls: calls
       })
       when is_binary(checkpoint_id) and checkpoint_id != "" and is_binary(request_id) and
              request_id != "" and is_list(messages) and is_list(calls) and calls != [] do
    case validate_messages(messages) do
      :ok -> validate_restored_checkpoint_calls(calls)
      {:error, _reason} = error -> error
    end
  end

  defp validate_tool_checkpoint(_checkpoint), do: {:error, :invalid_tool_checkpoint}

  @spec validate_checkpoint_calls([map()]) :: :ok | {:error, term()}
  defp validate_checkpoint_calls(calls) do
    valid? =
      Enum.all?(calls, fn
        %{tool_call_id: id, name: name, arguments: arguments} ->
          is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(arguments)

        _call ->
          false
      end)

    ids = Enum.map(calls, &Map.get(&1, :tool_call_id))

    if valid? and Enum.uniq(ids) == ids,
      do: :ok,
      else: {:error, :invalid_checkpoint_calls}
  end

  @spec validate_restored_checkpoint_calls([checkpoint_call()]) :: :ok | {:error, term()}
  defp validate_restored_checkpoint_calls(calls) do
    with :ok <- validate_checkpoint_calls(calls) do
      if Enum.all?(calls, &valid_restored_checkpoint_call?/1),
        do: :ok,
        else: {:error, :invalid_checkpoint_call_status}
    end
  end

  @spec valid_restored_checkpoint_call?(checkpoint_call()) :: boolean()
  defp valid_restored_checkpoint_call?(%{status: status})
       when status in [:pending, :admitted],
       do: true

  defp valid_restored_checkpoint_call?(
         %{tool_call_id: tool_call_id, status: {:completed, %Message{} = result_message}} = call
       ) do
    validate_tool_result_identity(call, tool_call_id, result_message) == :ok
  end

  defp valid_restored_checkpoint_call?(_call), do: false

  @spec validate_checkpoint_progression(t(), [Message.t()]) :: :ok | {:error, term()}
  defp validate_checkpoint_progression(
         %__MODULE__{tool_checkpoint: nil, active_request: %Request{messages: request_messages}},
         messages
       ) do
    validate_initial_request_prefix(messages, request_messages)
  end

  defp validate_checkpoint_progression(
         %__MODULE__{tool_checkpoint: checkpoint},
         messages
       ) do
    completed_results =
      Enum.map(checkpoint.calls, fn
        %{status: {:completed, result_message}} -> result_message
        _unfinished -> nil
      end)

    if Enum.any?(completed_results, &is_nil/1) do
      {:error, :previous_tool_group_unresolved}
    else
      validate_message_prefix(messages, checkpoint.messages ++ completed_results)
    end
  end

  @spec validate_initial_request_prefix([Message.t()], [Message.t()]) :: :ok | {:error, term()}

  defp validate_initial_request_prefix(
         [%Message{role: :system} | messages],
         [%Message{role: role} | _] = request_messages
       )
       when role != :system do
    validate_message_prefix(messages, request_messages)
  end

  defp validate_initial_request_prefix(messages, request_messages) do
    validate_message_prefix(messages, request_messages)
  end

  @spec validate_message_prefix([Message.t()], [Message.t()]) :: :ok | {:error, term()}
  defp validate_message_prefix(messages, prefix) do
    prefix_count = length(prefix)

    if length(messages) > prefix_count and Enum.take(messages, prefix_count) == prefix,
      do: :ok,
      else: {:error, :invalid_checkpoint_progression}
  end

  @spec validate_outcome_checkpoint(tool_checkpoint() | nil, [Message.t()]) ::
          :ok | {:error, :unresolved_tool_checkpoint | :invalid_checkpoint_progression}
  defp validate_outcome_checkpoint(nil, _messages), do: :ok

  defp validate_outcome_checkpoint(checkpoint, messages) do
    results =
      Enum.map(checkpoint.calls, fn
        %{status: {:completed, result_message}} -> result_message
        _unfinished -> nil
      end)

    if Enum.any?(results, &is_nil/1),
      do: {:error, :unresolved_tool_checkpoint},
      else: validate_message_prefix(messages, checkpoint.messages ++ results)
  end

  @spec checkpoint_id(String.t(), [Message.t()], [map()]) :: String.t()
  defp checkpoint_id(request_id, messages, calls) do
    digest_source =
      {messages,
       Enum.map(calls, fn call ->
         {call.tool_call_id, call.name, call.arguments}
       end)}
      |> :erlang.term_to_binary()

    digest = :crypto.hash(:sha256, digest_source) |> Base.url_encode64(padding: false)

    request_id <> ":" <> digest
  end

  @spec find_checkpoint_call([checkpoint_call()], String.t()) ::
          {:ok, non_neg_integer(), checkpoint_call()} | {:error, :unknown_tool_call}
  defp find_checkpoint_call(calls, tool_call_id) do
    case Enum.find_index(calls, &(&1.tool_call_id == tool_call_id)) do
      nil -> {:error, :unknown_tool_call}
      index -> {:ok, index, Enum.at(calls, index)}
    end
  end

  @spec reconciliation_result(checkpoint_call()) :: {Message.t(), atom()}
  defp reconciliation_result(%{status: {:completed, %Message{} = message}}),
    do: {message, :completed}

  defp reconciliation_result(%{status: :admitted} = call) do
    message =
      Context.tool_result_message(
        call.name,
        call.tool_call_id,
        "Tool effect outcome is indeterminate after interruption. The call was not rerun.",
        %{is_error: true, minga_effect_status: :indeterminate}
      )

    {message, :indeterminate}
  end

  defp reconciliation_result(%{status: :pending} = call) do
    message =
      Context.tool_result_message(
        call.name,
        call.tool_call_id,
        "Tool call was not executed because interruption occurred before durable effect admission.",
        %{is_error: true, minga_effect_status: :not_executed}
      )

    {message, :not_executed}
  end

  @spec valid_message_attachments?(Message.t()) :: boolean()
  defp valid_message_attachments?(%Message{content: content}) do
    Enum.all?(content, &valid_content_part?/1)
  end

  @spec valid_content_part?(term()) :: boolean()
  defp valid_content_part?(%ContentPart{type: :image, data: data}), do: is_binary(data)

  defp valid_content_part?(%ContentPart{type: :file, data: data, file_id: file_id}),
    do: is_binary(data) or (is_binary(file_id) and file_id != "")

  defp valid_content_part?(%ContentPart{}), do: true
  defp valid_content_part?(part) when is_map(part), do: true
  defp valid_content_part?(_part), do: false
end

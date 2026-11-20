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
  alias MingaAgent.Session.Prefix
  alias MingaAgent.Session.PrefixStore
  alias MingaAgent.Session.PortableHistory
  alias MingaAgent.Session.Transcript
  alias MingaAgent.ToolCall, as: DisplayToolCall
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @typep tool_call_ids :: MapSet.t(String.t())

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
          calls: [checkpoint_call()],
          epoch_id: PrefixStore.epoch_ref()
        }

  @typep checkpoint_selection :: {tool_checkpoint(), non_neg_integer(), checkpoint_call()}

  @typedoc "Completed model boundary correlated to the last display entry it produced."
  @type boundary :: %{
          transcript_id: pos_integer(),
          message_count: non_neg_integer(),
          revision: non_neg_integer(),
          epoch_id: PrefixStore.epoch_ref()
        }

  @typedoc "Lossless model history and boundary identities for one saved display branch."
  @type branch_snapshot :: %{
          messages: [Message.t()],
          boundaries: [boundary()],
          epoch_id: PrefixStore.epoch_ref()
        }

  @typedoc "Session-owned continuation state."
  @type t :: %__MODULE__{
          messages: [Message.t()],
          revision: non_neg_integer(),
          durable_revision: non_neg_integer(),
          active_request: Request.t() | nil,
          tool_checkpoint: tool_checkpoint() | nil,
          boundaries: [boundary()],
          branch_messages: %{String.t() => branch_snapshot()},
          provenance: provenance(),
          prefixes: PrefixStore.t()
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
  defstruct @enforce_keys ++ [prefixes: %PrefixStore{}]

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

  @doc "Restores versioned host outcomes; only supported legacy records receive legacy defaults."
  @spec restore_tool_outcomes(t(), 2 | 3 | 4 | 5 | 6, Transcript.t()) ::
          {:ok, t()} | {:error, :invalid_tool_outcome}
  def restore_tool_outcomes(%__MODULE__{} = continuation, 6, %Transcript{}) do
    if Enum.all?(continuation.messages, &valid_result_outcome?/1) and
         Enum.all?(continuation.branch_messages, fn {_name, branch} ->
           Enum.all?(branch.messages, &valid_result_outcome?/1)
         end) and valid_request_outcomes?(continuation.active_request) and
         valid_checkpoint_outcomes?(continuation.tool_checkpoint),
       do: {:ok, continuation},
       else: {:error, :invalid_tool_outcome}
  end

  def restore_tool_outcomes(%__MODULE__{} = continuation, version, %Transcript{} = transcript)
      when version in [2, 3, 4, 5] do
    with {:ok, messages} <- restore_tool_messages(continuation.messages, version),
         {:ok, branches} <- restore_tool_branches(continuation.branch_messages, version),
         {:ok, request} <- restore_tool_request(continuation.active_request, version),
         {:ok, checkpoint} <-
           restore_checkpoint_outcomes(continuation.tool_checkpoint, version, transcript) do
      {:ok,
       %{
         continuation
         | messages: messages,
           branch_messages: branches,
           active_request: request,
           tool_checkpoint: checkpoint
       }}
    end
  end

  defp restore_tool_messages(messages, version) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, reversed} ->
      case restore_tool_message(message, version, nil) do
        {:ok, message} -> {:cont, {:ok, [message | reversed]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> reverse_restored_messages()
  end

  defp reverse_restored_messages({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp reverse_restored_messages({:error, _} = error), do: error

  defp valid_result_outcome?(%Message{role: :tool, metadata: metadata}),
    do: match?({:ok, _outcome, _reason}, DisplayToolCall.saved_outcome(metadata))

  defp valid_result_outcome?(_message), do: true

  defp valid_request_outcomes?(nil), do: true

  defp valid_request_outcomes?(%Request{messages: messages}),
    do: Enum.all?(messages, &valid_result_outcome?/1)

  defp valid_checkpoint_outcomes?(nil), do: true

  defp valid_checkpoint_outcomes?(checkpoint) do
    Enum.all?(checkpoint.messages, &valid_result_outcome?/1) and
      Enum.all?(checkpoint.calls, &valid_checkpoint_call_outcome?/1)
  end

  defp valid_checkpoint_call_outcome?(%{status: {:completed, result}}),
    do: valid_result_outcome?(result)

  defp valid_checkpoint_call_outcome?(%{status: status}) when status in [:pending, :admitted],
    do: true

  defp restore_tool_message(
         %Message{role: :tool, metadata: metadata} = message,
         version,
         fallback
       )
       when version in [2, 3, 4, 5] do
    case legacy_tool_outcome(metadata, fallback) do
      {:ok, outcome} ->
        metadata =
          metadata
          |> Map.put(:tool_outcome, outcome)
          |> Map.put(:is_error, outcome != :complete)
          |> Map.delete(:tool_outcome_reason)

        {:ok, %{message | metadata: metadata}}

      {:error, _} = error ->
        error
    end
  end

  defp restore_tool_message(message, _version, _fallback), do: {:ok, message}

  defp legacy_tool_outcome(%{minga_effect_status: status}, _fallback)
       when status in [:indeterminate, :not_executed], do: {:ok, :error}

  defp legacy_tool_outcome(%{is_error: true}, _fallback), do: {:ok, :error}
  defp legacy_tool_outcome(%{is_error: false}, _fallback), do: {:ok, :complete}
  defp legacy_tool_outcome(%{is_error: _invalid}, _fallback), do: {:error, :invalid_tool_outcome}

  defp legacy_tool_outcome(_metadata, %DisplayToolCall{status: status})
       when status in [:complete, :denied, :cancelled, :error], do: {:ok, status}

  defp legacy_tool_outcome(_metadata, _no_terminal_fact), do: {:ok, :complete}

  defp restore_tool_branches(branches, version) do
    Enum.reduce_while(branches, {:ok, %{}}, fn {name, snapshot}, {:ok, restored} ->
      case restore_tool_messages(snapshot.messages, version) do
        {:ok, messages} ->
          {:cont, {:ok, Map.put(restored, name, %{snapshot | messages: messages})}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp restore_tool_request(nil, _version), do: {:ok, nil}

  defp restore_tool_request(%Request{} = request, version) do
    with {:ok, messages} <- restore_tool_messages(request.messages, version),
         do: {:ok, Request.restore_messages(request, messages)}
  end

  defp restore_checkpoint_outcomes(nil, _version, _transcript), do: {:ok, nil}

  defp restore_checkpoint_outcomes(checkpoint, version, transcript) do
    with {:ok, messages} <- restore_tool_messages(checkpoint.messages, version),
         {:ok, calls} <- restore_checkpoint_call_outcomes(checkpoint.calls, version, transcript) do
      {:ok, %{checkpoint | messages: messages, calls: calls}}
    end
  end

  defp restore_checkpoint_call_outcomes(calls, version, transcript) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, reversed} ->
      case restore_checkpoint_call_outcome(call, version, transcript) do
        {:ok, call} -> {:cont, {:ok, [call | reversed]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> reverse_restored_messages()
  end

  defp restore_checkpoint_call_outcome(
         %{status: {:completed, result}} = call,
         version,
         transcript
       ) do
    fallback = legacy_checkpoint_tool(version, transcript, call.tool_call_id)

    with {:ok, result} <- restore_tool_message(result, version, fallback),
         do: {:ok, %{call | status: {:completed, result}}}
  end

  defp restore_checkpoint_call_outcome(call, _version, _transcript), do: {:ok, call}

  defp legacy_checkpoint_tool(version, transcript, id) when version in [2, 3, 4, 5],
    do: Transcript.current_tool_call(transcript, id)

  @doc "Admits prefix changes only at a whole-request idle boundary."
  @spec change_prefix(t(), Prefix.t()) ::
          {:ok, :unchanged | :applied, t()} | {:error, term()}
  def change_prefix(%__MODULE__{active_request: %Request{}}, %Prefix{}),
    do: {:error, :request_active}

  def change_prefix(%__MODULE__{tool_checkpoint: %{}}, %Prefix{}),
    do: {:error, :effect_reconciliation_required}

  def change_prefix(
        %__MODULE__{prefixes: %{selected: id}} = continuation,
        %Prefix{epoch_id: id}
      ),
      do: {:ok, :unchanged, continuation}

  def change_prefix(
        %__MODULE__{messages: [], boundaries: []} = continuation,
        %Prefix{} = candidate
      ) do
    prefixes = select_prefix(continuation, candidate)

    {:ok, :applied,
     %{
       continuation
       | prefixes: prefixes,
         messages: [Context.system(candidate.instructions)],
         revision: continuation.revision + 1
     }}
  end

  def change_prefix(
        %__MODULE__{
          messages: [%Message{role: :system}],
          boundaries: [],
          prefixes: %{selected: selected}
        } = continuation,
        %Prefix{} = candidate
      )
      when is_binary(selected) do
    prefixes = select_prefix(continuation, candidate)

    {:ok, :applied,
     %{
       continuation
       | prefixes: prefixes,
         messages: [Context.system(candidate.instructions)],
         revision: continuation.revision + 1
     }}
  end

  def change_prefix(%__MODULE__{} = continuation, %Prefix{} = candidate) do
    with %Prefix{} = captured <-
           PrefixStore.resolve(continuation.prefixes, continuation.prefixes.selected),
         true <- Prefix.requalifies?(captured, candidate) do
      {:ok, :unchanged, continuation}
    else
      _changed_or_missing -> prefix_transition_required(continuation, candidate)
    end
  end

  @spec prefix_transition_required(t(), Prefix.t()) :: {:error, term()}
  defp prefix_transition_required(continuation, candidate) do
    {:error,
     {:portable_context_transition_required,
      %{
        epoch_id: continuation.prefixes.selected,
        candidate_epoch_id: candidate.epoch_id,
        reason: transition_reason(continuation.prefixes.selected, candidate),
        actions: [:cancel_retain, :new_session],
        message:
          "Retained context cannot use these instruction, schema, route or authentication inputs. Cancel to retain it, or use /new for a fresh conversation; the saved conversation is preserved."
      }}}
  end

  @spec transition_reason(PrefixStore.epoch_ref(), Prefix.t()) :: atom()
  defp transition_reason(:unknown, _candidate), do: :historical_identity_unknown

  defp transition_reason(_epoch_id, %Prefix{identity: %{native_contract: :unknown}}),
    do: :native_contract_unknown

  defp transition_reason(_epoch_id, _candidate), do: :native_identity_changed

  @doc "Hands completed active history to a new model without provider-private replay state."
  @spec change_model_prefix(t(), Prefix.t(), PortableHistory.file_policy()) ::
          {:ok, :applied, t()} | {:error, term()}
  def change_model_prefix(continuation, candidate, file_policy \\ :reject)

  def change_model_prefix(%__MODULE__{active_request: %Request{}}, %Prefix{}, _file_policy),
    do: {:error, :request_active}

  def change_model_prefix(%__MODULE__{tool_checkpoint: %{}}, %Prefix{}, _file_policy),
    do: {:error, :effect_reconciliation_required}

  def change_model_prefix(%__MODULE__{} = continuation, %Prefix{} = candidate, file_policy) do
    file_policy = authenticated_file_policy(continuation, candidate, file_policy)

    with {:ok, messages, counts} <- PortableHistory.convert(continuation.messages, file_policy) do
      {messages, offset} = replace_model_instructions(messages, candidate.instructions)

      boundaries =
        Enum.map(continuation.boundaries, fn boundary ->
          %{
            boundary
            | message_count: Map.fetch!(counts, boundary.message_count) + offset,
              epoch_id: candidate.epoch_id
          }
        end)

      updated = %{
        continuation
        | messages: messages,
          boundaries: boundaries,
          revision: continuation.revision + 1,
          prefixes: PrefixStore.select(continuation.prefixes, candidate)
      }

      {:ok, :applied, prune_prefixes(updated)}
    end
  end

  @spec authenticated_file_policy(t(), Prefix.t(), PortableHistory.file_policy()) ::
          PortableHistory.file_policy()
  defp authenticated_file_policy(
         continuation,
         %Prefix{identity: %{authentication: authentication}},
         :retain
       ) do
    case PrefixStore.resolve(continuation.prefixes, continuation.prefixes.selected) do
      %Prefix{identity: %{authentication: ^authentication}} -> :retain
      _different_namespace -> :reject
    end
  end

  defp authenticated_file_policy(_continuation, _candidate, _policy), do: :reject

  @spec replace_model_instructions([Message.t()], String.t()) :: {[Message.t()], 0 | 1}
  defp replace_model_instructions([%Message{role: :system} | rest], instructions),
    do: {[Context.system(instructions) | rest], 0}

  defp replace_model_instructions(messages, instructions),
    do: {[Context.system(instructions) | messages], 1}

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
      prefix = PrefixStore.resolve(continuation.prefixes, continuation.prefixes.selected)
      request = Request.new(request_id, turn_id, continuation.revision, messages, prefix)
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
          revision: revision,
          epoch_id: request.epoch_id
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
      revision: revision,
      epoch_id: continuation.active_request.epoch_id
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
      boundaries: continuation.boundaries,
      epoch_id: continuation.prefixes.selected
    }

    branch_messages = Map.put(continuation.branch_messages, branch_name, branch_snapshot)
    revision = continuation.revision + 1

    case matching_boundary(continuation.boundaries, transcript_id) do
      nil ->
        {:error, :branch_not_resumable}

      boundary ->
        updated =
          %{
            continuation
            | messages: Enum.take(continuation.messages, boundary.message_count),
              revision: revision,
              active_request: nil,
              tool_checkpoint: nil,
              boundaries:
                Enum.filter(continuation.boundaries, &(&1.revision <= boundary.revision)),
              branch_messages: branch_messages,
              prefixes:
                PrefixStore.select_epoch(
                  continuation.prefixes,
                  Map.get(boundary, :epoch_id, :unknown)
                )
          }

        {:ok, prune_prefixes(updated)}
    end
  end

  @doc "Restores the lossless model values captured for a named display branch."
  @spec switch_branch(t(), String.t()) :: {:ok, t()} | {:error, :branch_not_resumable}
  def switch_branch(%__MODULE__{} = continuation, branch_name) when is_binary(branch_name) do
    case Map.fetch(continuation.branch_messages, branch_name) do
      {:ok, %{messages: messages, boundaries: boundaries} = snapshot} ->
        revision = continuation.revision + 1

        updated =
          %{
            continuation
            | messages: messages,
              revision: revision,
              active_request: nil,
              tool_checkpoint: nil,
              boundaries: boundaries,
              prefixes:
                PrefixStore.select_epoch(
                  continuation.prefixes,
                  Map.get(snapshot, :epoch_id, :unknown)
                )
          }

        {:ok, prune_prefixes(updated)}

      :error ->
        {:error, :branch_not_resumable}
    end
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
            [
              %{
                transcript_id: transcript_id,
                message_count: length(messages),
                revision: revision,
                epoch_id: continuation.prefixes.selected
              }
            ]

          [] ->
            []
        end

      updated = %{continuation | messages: messages, revision: revision, boundaries: boundaries}
      {:ok, prune_prefixes(updated)}
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
        revision: revision,
        epoch_id: continuation.prefixes.selected
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

  @typedoc "Optional in-flight request and interned prefixes restored with a continuation."
  @type restore_option :: {:active_request, Request.t() | nil} | {:prefixes, PrefixStore.t()}

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
          [restore_option()]
        ) :: {:ok, t()} | {:error, term()}
  def restore(
        messages,
        revision,
        durable_revision,
        boundaries,
        branch_messages,
        provenance,
        tool_checkpoint \\ nil,
        opts \\ []
      )
      when is_list(messages) and is_integer(revision) and revision >= 0 and
             is_integer(durable_revision) and durable_revision >= 0 and is_list(boundaries) and
             is_map(branch_messages) and provenance in [:lossless, :legacy_reconstructed] and
             is_list(opts) do
    active_request = Keyword.get(opts, :active_request)
    prefixes = Keyword.get(opts, :prefixes, %PrefixStore{})

    with :ok <- validate_messages(messages),
         :ok <- validate_boundaries(boundaries, length(messages), revision),
         true <- durable_revision <= revision or {:error, :invalid_durable_revision},
         :ok <- validate_branches(branch_messages),
         :ok <- validate_tool_checkpoint(tool_checkpoint),
         :ok <- validate_active_request(active_request, revision, messages, tool_checkpoint),
         {:ok, prefixes} <-
           validate_epoch_references(
             prefixes,
             boundaries,
             branch_messages,
             tool_checkpoint,
             active_request
           ) do
      active_request = resolve_request_prefix(active_request, prefixes)

      {:ok,
       %__MODULE__{
         messages: messages,
         revision: revision,
         durable_revision: durable_revision,
         active_request: active_request,
         tool_checkpoint: tool_checkpoint,
         boundaries: boundaries,
         branch_messages: branch_messages,
         provenance: provenance,
         prefixes: prefixes
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec resolve_request_prefix(Request.t() | nil, PrefixStore.t()) :: Request.t() | nil
  defp resolve_request_prefix(nil, _prefixes), do: nil

  defp resolve_request_prefix(request, prefixes),
    do: Request.resolve_prefix(request, prefixes, request.epoch_id)

  @spec validate_epoch_references(
          PrefixStore.t(),
          [boundary()],
          map(),
          map() | nil,
          Request.t() | nil
        ) ::
          {:ok, PrefixStore.t()} | {:error, :dangling_prefix_epoch | :inconsistent_prefix_epoch}
  defp validate_epoch_references(prefixes, boundaries, branches, checkpoint, request) do
    roots = [prefixes.selected | prefix_roots(boundaries, branches, checkpoint, request)]

    with true <-
           Enum.all?(roots, &PrefixStore.known?(prefixes, &1)) or {:error, :dangling_prefix_epoch},
         true <-
           (epoch_matches?(prefixes.selected, checkpoint) and
              epoch_matches?(prefixes.selected, request) and
              epoch_matches?(prefixes.selected, List.last(boundaries))) or
             {:error, :inconsistent_prefix_epoch},
         true <-
           Enum.all?(branches, fn {_name, snapshot} ->
             epoch_matches?(epoch_reference(snapshot), List.last(snapshot.boundaries))
           end) or {:error, :inconsistent_prefix_epoch} do
      {:ok, PrefixStore.retain(prefixes, roots)}
    end
  end

  @spec epoch_matches?(PrefixStore.epoch_ref(), map() | nil) :: boolean()
  defp epoch_matches?(_selected, nil), do: true
  defp epoch_matches?(selected, value), do: epoch_reference(value) == selected

  @spec select_prefix(t(), Prefix.t()) :: PrefixStore.t()
  defp select_prefix(continuation, candidate) do
    prefixes = PrefixStore.select(continuation.prefixes, candidate)

    roots =
      prefix_roots(
        continuation.boundaries,
        continuation.branch_messages,
        continuation.tool_checkpoint,
        continuation.active_request
      )

    PrefixStore.retain(prefixes, roots)
  end

  @spec prune_prefixes(t()) :: t()
  defp prune_prefixes(continuation) do
    roots =
      prefix_roots(
        continuation.boundaries,
        continuation.branch_messages,
        continuation.tool_checkpoint,
        continuation.active_request
      )

    %{continuation | prefixes: PrefixStore.retain(continuation.prefixes, roots)}
  end

  @spec prefix_roots([boundary()], map(), map() | nil, Request.t() | nil) ::
          [PrefixStore.epoch_ref()]
  defp prefix_roots(boundaries, branches, checkpoint, request) do
    [epoch_reference(checkpoint), epoch_reference(request)] ++
      Enum.map(boundaries, &epoch_reference/1) ++
      Enum.flat_map(branches, fn {_name, snapshot} ->
        [epoch_reference(snapshot) | Enum.map(snapshot.boundaries, &epoch_reference/1)]
      end)
  end

  @spec epoch_reference(map() | nil) :: PrefixStore.epoch_ref()
  defp epoch_reference(nil), do: :unknown
  defp epoch_reference(value), do: Map.get(value, :epoch_id, :unknown)

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
         {:ok, call_ids} <- validate_checkpoint_calls(calls),
         :ok <- validate_checkpoint_progression(continuation, messages, call_ids) do
      checkpoint_id = checkpoint_id(request_id, messages, calls)

      checkpoint = %{
        version: 1,
        checkpoint_id: checkpoint_id,
        request_id: request_id,
        messages: messages,
        epoch_id: continuation.active_request.epoch_id,
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
      ) do
    with {:ok, {_, _, call} = selection} <-
           select_checkpoint_call(checkpoint, request_id, checkpoint_id, tool_call_id),
         true <-
           (call.name == name and call.arguments == arguments) or
             {:error, :tool_call_identity_mismatch},
         :pending <- call.status do
      {:ok, replace_checkpoint_status(continuation, selection, :admitted)}
    else
      :admitted -> {:error, :duplicate_admission}
      {:completed, _message} -> {:error, :duplicate_admission}
      {:error, _reason} = error -> error
    end
  end

  @doc "Records the exact terminal tool-result message against its original call identity."
  @spec complete_tool_effect(t(), String.t(), String.t(), String.t(), Message.t()) ::
          {:ok, t()} | {:error, term()}
  def complete_tool_effect(
        %__MODULE__{tool_checkpoint: checkpoint} = continuation,
        request_id,
        checkpoint_id,
        tool_call_id,
        %Message{} = result_message
      ) do
    with {:ok, selection} <-
           select_checkpoint_call(checkpoint, request_id, checkpoint_id, tool_call_id) do
      complete_checkpoint_call(continuation, selection, tool_call_id, result_message)
    end
  end

  @spec complete_checkpoint_call(t(), checkpoint_selection(), String.t(), Message.t()) ::
          {:ok, t()} | {:error, :tool_result_identity_mismatch | :conflicting_tool_outcome}
  defp complete_checkpoint_call(continuation, {_, _, call} = selection, tool_call_id, result) do
    with :ok <- validate_tool_result_identity(call, tool_call_id, result) do
      case call.status do
        {:completed, ^result} ->
          {:ok, continuation}

        {:completed, _different_message} ->
          {:error, :conflicting_tool_outcome}

        status when status in [:pending, :admitted] ->
          {:ok, replace_checkpoint_status(continuation, selection, {:completed, result})}
      end
    end
  end

  @doc "Records explicit Stop only for the exact still-unadmitted checkpoint call."
  @spec cancel_unadmitted_tool(t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:already_completed, Message.t()} | {:error, term()}
  def cancel_unadmitted_tool(
        %__MODULE__{
          active_request: %Request{request_id: request_id},
          tool_checkpoint: %{request_id: request_id, checkpoint_id: checkpoint_id} = checkpoint
        } = continuation,
        request_id,
        checkpoint_id,
        tool_call_id
      ) do
    with {:ok, selection} <- select_checkpoint_call(checkpoint, tool_call_id) do
      cancel_checkpoint_call(continuation, selection)
    end
  end

  def cancel_unadmitted_tool(%__MODULE__{}, _request, _checkpoint, _tool),
    do: {:error, :stale_checkpoint}

  @spec cancel_checkpoint_call(t(), checkpoint_selection()) ::
          {:ok, t()} | {:already_completed, Message.t()} | {:error, term()}
  defp cancel_checkpoint_call(continuation, {_, _, %{status: :pending} = call} = selection) do
    result =
      Context.tool_result_message(call.name, call.tool_call_id, "Cancelled before approval", %{
        tool_outcome: :cancelled,
        is_error: true,
        minga_effect_status: :not_executed
      })

    complete_checkpoint_call(continuation, selection, call.tool_call_id, result)
  end

  defp cancel_checkpoint_call(_continuation, {_, _, %{status: :admitted}}),
    do: {:error, :effect_already_admitted}

  defp cancel_checkpoint_call(_continuation, {_, _, %{status: {:completed, result}}}),
    do: {:already_completed, result}

  @spec replace_checkpoint_status(t(), checkpoint_selection(), tool_call_status()) :: t()
  defp replace_checkpoint_status(continuation, {checkpoint, index, call}, status) do
    calls = List.replace_at(checkpoint.calls, index, %{call | status: status})
    %{continuation | tool_checkpoint: %{checkpoint | calls: calls}}
  end

  @doc "Finds terminal calls in the active Request without treating historical results as current approvals."
  @spec tool_call_completed?(t(), String.t()) :: boolean()
  def tool_call_completed?(
        %__MODULE__{
          active_request: %Request{messages: initial},
          tool_checkpoint: %{calls: calls, messages: messages}
        },
        tool_call_id
      )
      when is_binary(tool_call_id) do
    case Enum.find(calls, &(&1.tool_call_id == tool_call_id)) do
      %{status: {:completed, _result}} -> true
      nil -> request_tool_result?(messages, initial, tool_call_id)
      _pending_or_admitted -> false
    end
  end

  def tool_call_completed?(
        %__MODULE__{active_request: %Request{messages: initial}, messages: messages},
        tool_call_id
      )
      when is_binary(tool_call_id),
      do: request_tool_result?(messages, initial, tool_call_id)

  def tool_call_completed?(%__MODULE__{}, tool_call_id) when is_binary(tool_call_id), do: false

  @spec request_tool_result?([Message.t()], [Message.t()], String.t()) :: boolean()
  defp request_tool_result?([_message | messages], [_initial | initial], tool_call_id),
    do: request_tool_result?(messages, initial, tool_call_id)

  defp request_tool_result?(messages, [], tool_call_id),
    do: Enum.any?(messages, &match?(%Message{role: :tool, tool_call_id: ^tool_call_id}, &1))

  defp request_tool_result?([], _initial, _tool_call_id), do: false

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
  def reconcile_interrupted(%__MODULE__{} = continuation, transcript_id),
    do: reconcile_interrupted(continuation, transcript_id, %{})

  @doc "Reconciles with any separately proven durable capture facts keyed by tool call ID."
  @spec reconcile_interrupted(t(), pos_integer(), %{optional(String.t()) => term()}) ::
          {t(), [map()]}
  def reconcile_interrupted(
        %__MODULE__{tool_checkpoint: nil} = continuation,
        _transcript_id,
        _outputs
      ),
      do: {continuation, []}

  def reconcile_interrupted(
        %__MODULE__{tool_checkpoint: checkpoint} = continuation,
        transcript_id,
        outputs
      )
      when is_integer(transcript_id) and transcript_id > 0 and is_map(outputs) do
    {result_messages, reversed_reconciliation} =
      Enum.map_reduce(checkpoint.calls, [], fn call, statuses ->
        {message, status} = reconciliation_result(call, Map.get(outputs, call.tool_call_id))

        output = Map.get(outputs, call.tool_call_id)

        reconciliation =
          %{
            tool_call_id: call.tool_call_id,
            name: call.name,
            status: status,
            result_message: message
          }
          |> maybe_put_output(output)

        {message, [reconciliation | statuses]}
      end)

    reconciliation = Enum.reverse(reversed_reconciliation)
    revision = continuation.revision + 1

    boundary = %{
      transcript_id: transcript_id,
      message_count: length(checkpoint.messages) + length(result_messages),
      revision: revision,
      epoch_id: Map.get(checkpoint, :epoch_id, :unknown)
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
      request.conversation_revision == outcome.conversation_revision and outcome.version == 1 and
      request.epoch_id == outcome.epoch_id
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
      boundary.message_count >= previous.message_count and
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

  @spec validate_checkpoint_calls([map()]) :: {:ok, tool_call_ids()} | {:error, term()}
  defp validate_checkpoint_calls(calls) do
    Enum.reduce_while(calls, {:ok, MapSet.new()}, fn
      %{tool_call_id: id, name: name, arguments: arguments}, {:ok, ids}
      when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(arguments) ->
        if MapSet.member?(ids, id) do
          {:halt, {:error, :invalid_checkpoint_calls}}
        else
          {:cont, {:ok, MapSet.put(ids, id)}}
        end

      _call, _ids ->
        {:halt, {:error, :invalid_checkpoint_calls}}
    end)
  end

  @spec validate_restored_checkpoint_calls([checkpoint_call()]) :: :ok | {:error, term()}
  defp validate_restored_checkpoint_calls(calls) do
    with {:ok, _call_ids} <- validate_checkpoint_calls(calls) do
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

  @spec validate_checkpoint_progression(t(), [Message.t()], tool_call_ids()) ::
          :ok | {:error, term()}
  defp validate_checkpoint_progression(
         %__MODULE__{tool_checkpoint: nil, active_request: %Request{messages: request_messages}},
         messages,
         _call_ids
       ) do
    validate_initial_request_prefix(messages, request_messages)
  end

  defp validate_checkpoint_progression(
         %__MODULE__{
           tool_checkpoint: checkpoint,
           active_request: %Request{messages: request_messages}
         },
         messages,
         call_ids
       ) do
    completed_results =
      Enum.map(checkpoint.calls, fn
        %{status: {:completed, result_message}} -> result_message
        _unfinished -> nil
      end)

    if Enum.any?(completed_results, &is_nil/1) do
      {:error, :previous_tool_group_unresolved}
    else
      with {:ok, remaining} <-
             consume_checkpoint_prefix(checkpoint.messages, messages, request_messages, call_ids) do
        validate_message_prefix(remaining, completed_results)
      end
    end
  end

  # The admitted prefix can contain earlier requests' IDs; only its later messages belong to this request.
  @spec consume_checkpoint_prefix(
          [Message.t()],
          [Message.t()],
          [Message.t()],
          tool_call_ids()
        ) ::
          {:ok, [Message.t()]} | {:error, :invalid_checkpoint_progression | :reused_tool_call_id}
  defp consume_checkpoint_prefix(
         [message | checkpoint_tail],
         [message | messages_tail],
         [_request_message | request_tail],
         call_ids
       ) do
    consume_checkpoint_prefix(checkpoint_tail, messages_tail, request_tail, call_ids)
  end

  defp consume_checkpoint_prefix(
         [message | checkpoint_tail],
         [message | messages_tail],
         [],
         call_ids
       ) do
    case reuses_tool_call_id?(message, call_ids) do
      true -> {:error, :reused_tool_call_id}
      false -> consume_checkpoint_prefix(checkpoint_tail, messages_tail, [], call_ids)
    end
  end

  defp consume_checkpoint_prefix([], messages, [], _call_ids), do: {:ok, messages}

  defp consume_checkpoint_prefix(_checkpoint, _messages, _request, _call_ids),
    do: {:error, :invalid_checkpoint_progression}

  @spec reuses_tool_call_id?(Message.t(), tool_call_ids()) :: boolean()
  defp reuses_tool_call_id?(%Message{role: :assistant, tool_calls: [_ | _] = calls}, call_ids) do
    Enum.any?(calls, &MapSet.member?(call_ids, &1.id))
  end

  defp reuses_tool_call_id?(_message, _call_ids), do: false

  @spec validate_initial_request_prefix([Message.t()], [Message.t()]) :: :ok | {:error, term()}

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

  @spec select_checkpoint_call(tool_checkpoint() | nil, String.t(), String.t(), String.t()) ::
          {:ok, checkpoint_selection()}
          | {:error,
             :missing_tool_checkpoint | :stale_request | :stale_checkpoint | :unknown_tool_call}
  defp select_checkpoint_call(checkpoint, request_id, checkpoint_id, tool_call_id)
       when is_map(checkpoint) do
    with true <- checkpoint.request_id == request_id or {:error, :stale_request},
         true <- checkpoint.checkpoint_id == checkpoint_id or {:error, :stale_checkpoint} do
      select_checkpoint_call(checkpoint, tool_call_id)
    end
  end

  defp select_checkpoint_call(_checkpoint, _request_id, _checkpoint_id, _tool_call_id),
    do: {:error, :missing_tool_checkpoint}

  @spec select_checkpoint_call(tool_checkpoint(), String.t()) ::
          {:ok, checkpoint_selection()} | {:error, :unknown_tool_call}
  defp select_checkpoint_call(checkpoint, tool_call_id),
    do: find_checkpoint_call(checkpoint.calls, tool_call_id, 0, checkpoint)

  @spec find_checkpoint_call(
          [checkpoint_call()],
          String.t(),
          non_neg_integer(),
          tool_checkpoint()
        ) ::
          {:ok, checkpoint_selection()} | {:error, :unknown_tool_call}
  defp find_checkpoint_call([%{tool_call_id: id} = call | _rest], tool_call_id, index, checkpoint)
       when id == tool_call_id,
       do: {:ok, {checkpoint, index, call}}

  defp find_checkpoint_call([_call | rest], tool_call_id, index, checkpoint),
    do: find_checkpoint_call(rest, tool_call_id, index + 1, checkpoint)

  defp find_checkpoint_call([], _tool_call_id, _index, _checkpoint),
    do: {:error, :unknown_tool_call}

  @spec reconciliation_result(checkpoint_call(), term()) :: {Message.t(), atom()}
  defp reconciliation_result(%{status: {:completed, %Message{} = message}}, _output),
    do: {message, :completed}

  defp reconciliation_result(%{name: "ask_user", status: :admitted} = call, _output) do
    message =
      Context.tool_result_message(
        call.name,
        call.tool_call_id,
        "Clarification interrupted before an answer was saved. No answer was assumed.",
        %{is_error: true, tool_outcome: :error, minga_effect_status: :indeterminate}
      )

    {message, :indeterminate}
  end

  defp reconciliation_result(%{status: :admitted} = call, output) do
    metadata =
      %{is_error: true, tool_outcome: :error, minga_effect_status: :indeterminate}
      |> maybe_put_output(output)

    message =
      Context.tool_result_message(
        call.name,
        call.tool_call_id,
        "Tool effect outcome is indeterminate after interruption. The call was not rerun.",
        metadata
      )

    {message, :indeterminate}
  end

  defp reconciliation_result(%{status: :pending} = call, _output) do
    message =
      Context.tool_result_message(
        call.name,
        call.tool_call_id,
        "Tool call was not executed because interruption occurred before durable effect admission.",
        %{is_error: true, tool_outcome: :error, minga_effect_status: :not_executed}
      )

    {message, :not_executed}
  end

  @spec maybe_put_output(map(), term()) :: map()
  defp maybe_put_output(metadata, nil), do: metadata
  defp maybe_put_output(metadata, output), do: Map.put(metadata, :output, output)

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

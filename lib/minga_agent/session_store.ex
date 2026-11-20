defmodule MingaAgent.SessionStore do
  @moduledoc """
  Persists agent conversations to disk as JSON files.

  Each session is saved as `{session_id}.json` in the sessions directory
  (`~/.config/minga/agent/sessions/` by default). Files are written
  atomically via a temp file + rename to avoid corruption on crash.
  Manager-owned remote identity is stored separately under `.remote_tokens/`.

  The store is stateless: all functions operate directly on the filesystem.
  The `Session` GenServer calls `save/2` on a debounced timer, and the
  picker calls `list/0` to scan the directory for past sessions.
  """

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStores
  alias MingaAgent.Checklist
  alias MingaAgent.DraftAttachment
  alias MingaAgent.DraftSnapshot
  alias MingaAgent.ModelSelection
  alias MingaAgent.ArtifactStorage.FaultInjector
  alias MingaAgent.Session.ChecklistArchive
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.ContinuationCodec
  alias MingaAgent.Session.Transcript
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Codec, as: OutputCodec
  alias MingaAgent.Tool.Output.Reference

  @version 6
  @legacy_version 2
  @envelope_version 7

  @type draft_revision :: non_neg_integer()
  @typep presentation :: {draft_revision(), DraftSnapshot.t() | nil}

  @typep snapshot_schema :: 2 | 4 | 5 | 6 | :model_v3 | :retention_v3

  @typedoc "Session metadata for the picker (without full message content)."
  @type session_meta :: %{
          id: String.t(),
          timestamp: String.t(),
          last_message_at: String.t(),
          title: String.t(),
          model_name: String.t(),
          provider_name: String.t(),
          preview: String.t(),
          recent_messages: String.t(),
          message_count: non_neg_integer(),
          turn_count: non_neg_integer(),
          cost: float(),
          archived?: boolean(),
          continuation_kind: :lossless | :legacy_reconstructed | :legacy_import_required
        }

  @typedoc "A saved conversation or a draft-only record, without any unsent text."
  @type recovery_entry :: {:conversation, session_meta()} | {:draft_only, String.t(), String.t()}

  @typedoc "Full session data for save/load."
  @type session_data :: %{
          required(:id) => String.t(),
          required(:timestamp) => String.t(),
          required(:model_name) => String.t(),
          required(:messages) => [MingaAgent.Message.t()],
          required(:usage) => MingaAgent.TurnUsage.t(),
          required(:continuation) => Continuation.t(),
          optional(:model_selection) => ModelSelection.t() | ModelSelection.Stored.t() | nil,
          optional(:selection_intent) => map(),
          optional(:last_message_at) => String.t(),
          optional(:title) => String.t(),
          optional(:custom_title) => String.t() | nil,
          optional(:archived?) => boolean(),
          optional(:provider_name) => String.t(),
          optional(:branches) => [MingaAgent.Branch.t()],
          optional(:message_ids) => [pos_integer()],
          optional(:pinned_ids) => MapSet.t(pos_integer()),
          optional(:memory) => String.t() | nil,
          optional(:checklist) => Checklist.t(),
          optional(:checklist_archive) => ChecklistArchive.t()
        }

  @typep deserialized_transcript_session :: %{
           required(:id) => String.t(),
           required(:timestamp) => String.t(),
           required(:last_message_at) => String.t(),
           required(:title) => String.t(),
           optional(:custom_title) => String.t() | nil,
           required(:archived?) => boolean(),
           required(:model_name) => String.t(),
           required(:provider_name) => String.t(),
           optional(:model_selection) => ModelSelection.Stored.t() | nil,
           optional(:selection_intent) => map(),
           required(:messages) => [MingaAgent.Message.t()],
           required(:message_ids) => [pos_integer()],
           required(:pinned_ids) => MapSet.t(pos_integer()),
           required(:usage) => MingaAgent.TurnUsage.t(),
           required(:branches) => [MingaAgent.Branch.t()],
           optional(:memory) => String.t() | nil
         }

  @typep remote_token_result :: {:ok, String.t()} | :missing | {:error, term()}

  @doc "Returns the sessions directory path."
  @spec sessions_dir(String.t() | nil) :: String.t()
  def sessions_dir(config_dir \\ nil) do
    config_dir =
      config_dir ||
        System.get_env("XDG_CONFIG_HOME") ||
        Path.join(System.user_home!(), ".config")

    Path.join([config_dir, "minga", "agent", "sessions"])
  end

  @doc """
  Saves a session to disk.

  Candidate artifact references are pinned before the private temporary file is
  written. The prior snapshot pin is released only after rename and parent
  directory synchronization make the candidate durable.
  """
  @spec save(session_data(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def save(%{id: id} = data, config_dir \\ nil, opts \\ [])
      when is_binary(id) and is_list(opts) do
    path = session_record_path(id, config_dir)

    result =
      with :ok <- validate_artifact_opts(opts) do
        with_record_workflow(path, fn -> commit_conversation(path, id, data, opts) end)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(:agent, "[SessionStore] failed to save #{id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Renames an existing saved conversation without changing its draft or transcript."
  @spec rename_conversation(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def rename_conversation(id, title, config_dir, opts) when is_binary(id) and is_binary(title) do
    with :ok <- validate_presentation_id(id),
         {:ok, title} <- normalize_title(title),
         :ok <- validate_artifact_opts(opts),
         path = session_record_path(id, config_dir),
         :ok <-
           with_record_workflow(path, fn ->
             update_conversation_metadata(path, id, {:rename, title}, opts)
           end) do
      {:ok, title}
    end
  end

  @doc "Archives or restores an existing saved conversation without modifying its work."
  @spec set_archived(String.t(), boolean(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def set_archived(id, archived?, config_dir, opts)
      when is_binary(id) and is_boolean(archived?) do
    with :ok <- validate_presentation_id(id),
         :ok <- validate_artifact_opts(opts) do
      path = session_record_path(id, config_dir)

      with_record_workflow(path, fn ->
        update_conversation_metadata(path, id, {:archive, archived?}, opts)
      end)
    end
  end

  @typep metadata_change :: {:rename, String.t()} | {:archive, boolean()}

  @spec normalize_title(String.t()) :: {:ok, String.t()} | {:error, :invalid_session_title}
  defp normalize_title(title) do
    if byte_size(title) <= 256 and String.valid?(title) and
         not String.match?(title, ~r/[\p{Cc}\p{Zl}\p{Zp}]/u) do
      case String.trim(title) do
        "" -> {:error, :invalid_session_title}
        title -> {:ok, title}
      end
    else
      {:error, :invalid_session_title}
    end
  end

  @spec update_conversation_metadata(String.t(), String.t(), metadata_change(), keyword()) ::
          :ok | {:error, term()}
  defp update_conversation_metadata(path, id, change, opts) do
    with {:ok, previous, _generation} <- read_record_for_write(path, id, opts),
         %{"version" => version} = conversation when version in [2, 3, 4, 5, @version] <-
           record_conversation(previous) do
      candidate =
        replace_record_conversation(previous, apply_metadata_change(conversation, change))

      commit_metadata_change(path, previous, candidate, change, opts)
    else
      {:error, _reason} = error -> error
      _unsupported -> {:error, :no_saved_conversation}
    end
  end

  @spec apply_metadata_change(map(), metadata_change()) :: map()
  defp apply_metadata_change(conversation, {:rename, title}),
    do: Map.put(conversation, "custom_title", title)

  defp apply_metadata_change(conversation, {:archive, true}),
    do: Map.put(conversation, "archived", true)

  defp apply_metadata_change(conversation, {:archive, false}),
    do: Map.delete(conversation, "archived")

  @spec commit_metadata_change(String.t(), map(), map(), metadata_change(), keyword()) ::
          :ok | {:error, term()}
  defp commit_metadata_change(_path, record, record, _change, _opts), do: :ok

  defp commit_metadata_change(path, _previous, candidate, {action, _value}, opts),
    do: write_metadata_record(path, candidate, action, opts)

  @spec replace_record_conversation(map(), map()) :: map()
  defp replace_record_conversation(%{"version" => @envelope_version} = record, conversation),
    do: Map.put(record, "conversation", conversation)

  defp replace_record_conversation(_record, conversation), do: conversation

  # Metadata-only changes leave the artifact generation and pins unchanged.
  @spec write_metadata_record(String.t(), map(), :rename | :archive, keyword()) ::
          :ok | {:error, term()}
  defp write_metadata_record(path, record, action, opts) do
    case atomic_write_private_result(path, JSON.encode!(record), fault_injector(opts)) do
      {:ok, :durable} ->
        :ok

      {:error, reason, :before_rename} ->
        {:error, reason}

      {:error, reason, :after_rename} ->
        confirm_metadata_commit(Path.dirname(path), action, reason)
    end
  end

  @spec confirm_metadata_commit(String.t(), :rename | :archive, term()) :: :ok | {:error, term()}
  defp confirm_metadata_commit(directory, action, reason) do
    case sync_directory(directory) do
      :ok -> :ok
      {:error, sync_reason} -> {:error, {uncertain_metadata_change(action), reason, sync_reason}}
    end
  end

  @spec uncertain_metadata_change(:rename | :archive) ::
          :session_rename_uncertain | :session_archive_uncertain
  defp uncertain_metadata_change(:rename), do: :session_rename_uncertain
  defp uncertain_metadata_change(:archive), do: :session_archive_uncertain

  @doc "Commits the admitted request and consumes the exact draft revision in the same record."
  @spec save_submitted_draft(session_data(), draft_revision(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def save_submitted_draft(%{id: id} = data, expected, config_dir, opts) do
    path = session_record_path(id, config_dir)

    with :ok <- validate_presentation_id(id),
         :ok <- validate_artifact_opts(opts) do
      with_record_workflow(path, fn ->
        commit_submitted_draft(path, id, data, expected, opts)
      end)
    end
  end

  @spec commit_submitted_draft(
          String.t(),
          String.t(),
          session_data(),
          draft_revision(),
          keyword()
        ) ::
          :ok | {:error, term()}
  defp commit_submitted_draft(path, id, data, expected, opts) do
    with {:ok, previous, previous_generation} <- read_record_for_write(path, id, opts),
         {:ok, {^expected, %DraftSnapshot{attachments: [_ | _]}}} <- decode_presentation(previous),
         presentation = %{"revision" => expected + 1, "draft" => nil},
         {:ok, encoded} <- encode_snapshot(data, presentation, previous) do
      save_record(path, id, encoded, previous_generation, opts, :admit_draft)
    else
      {:ok, {revision, _draft}} -> {:error, {:stale_draft_revision, revision}}
      {:error, _reason} = error -> error
    end
  end

  @spec commit_conversation(String.t(), String.t(), session_data(), keyword()) ::
          :ok | {:error, term()}
  defp commit_conversation(path, id, data, opts) do
    with {:ok, previous, previous_generation} <- read_record_for_write(path, id, opts),
         {:ok, encoded} <- encode_snapshot(data, Map.get(previous, "presentation"), previous) do
      save_record(path, id, encoded, previous_generation, opts)
    end
  end

  @doc "Reads the committed draft revision and snapshot. An absent draft has revision zero."
  @spec read_presentation(String.t(), String.t() | nil, keyword()) ::
          {:ok, draft_revision(), DraftSnapshot.t() | nil} | {:error, term()}
  def read_presentation(id, config_dir \\ nil, opts \\ []) when is_binary(id) and is_list(opts) do
    path = session_record_path(id, config_dir)

    with :ok <- validate_presentation_id(id),
         :ok <- validate_artifact_opts(opts) do
      with_record_workflow(path, fn -> read_committed_presentation(path, id, opts) end)
    end
  end

  @spec read_committed_presentation(String.t(), String.t(), keyword()) ::
          {:ok, draft_revision(), DraftSnapshot.t() | nil} | {:error, term()}
  defp read_committed_presentation(path, id, opts) do
    with {:ok, record, generation} <- read_record_for_write(path, id, opts),
         {:ok, {revision, draft}} <- decode_presentation(record),
         :ok <- reconcile_presentation_record(id, record, generation, opts) do
      {:ok, revision, draft}
    end
  end

  @doc "Reads an exact attachment only while its identity belongs to the unsent draft."
  @spec read_draft_attachment(String.t(), DraftAttachment.identity(), String.t() | nil, keyword()) ::
          {:ok, DraftSnapshot.attachment(), String.t()} | {:error, term()}
  def read_draft_attachment(id, identity, config_dir, opts) do
    path = session_record_path(id, config_dir)

    with :ok <- validate_presentation_id(id),
         :ok <- validate_artifact_opts(opts) do
      with_record_workflow(path, fn -> fetch_draft_attachment(path, id, identity, opts) end)
    end
  end

  @spec fetch_draft_attachment(String.t(), String.t(), DraftAttachment.identity(), keyword()) ::
          {:ok, DraftSnapshot.attachment(), String.t()} | {:error, term()}
  defp fetch_draft_attachment(path, id, identity, opts) do
    with {:ok, _revision, %DraftSnapshot{attachments: attachments}} <-
           read_committed_presentation(path, id, opts),
         {_, _, _, _, _} = attachment <-
           Enum.find(attachments, &(DraftAttachment.identity(&1) == identity)),
         {:ok, store} <- ensure_artifact_store(id, opts),
         {:ok, text} <- DraftAttachment.read_text(store, attachment) do
      {:ok, attachment, text}
    else
      {:error, _reason} = error -> error
      _missing -> {:error, :attachment_not_in_draft}
    end
  end

  @doc "Loads the entire ordered set shown by the composer, or rejects without returning partial context."
  @spec resolve_draft_attachments(
          String.t(),
          [DraftAttachment.identity()],
          String.t() | nil,
          keyword()
        ) ::
          {:ok, draft_revision(), [{DraftSnapshot.attachment(), String.t()}]} | {:error, term()}
  def resolve_draft_attachments(id, [_ | _] = shown, config_dir, opts) do
    path = session_record_path(id, config_dir)

    with :ok <- validate_presentation_id(id),
         :ok <- validate_artifact_opts(opts) do
      with_record_workflow(path, fn -> resolve_shown_attachments(path, id, shown, opts) end)
    end
  end

  @spec resolve_shown_attachments(String.t(), String.t(), [DraftAttachment.identity()], keyword()) ::
          {:ok, draft_revision(), [{DraftSnapshot.attachment(), String.t()}]} | {:error, term()}
  defp resolve_shown_attachments(path, id, shown, opts) do
    with {:ok, revision, %DraftSnapshot{attachments: attachments}} <-
           read_committed_presentation(path, id, opts),
         ^shown <- Enum.map(attachments, &DraftAttachment.identity/1),
         {:ok, store} <- ensure_artifact_store(id, opts),
         {:ok, resolved} <- resolve_attachment_text(store, attachments, [], 0) do
      {:ok, revision, resolved}
    else
      {:error, _reason} = error -> error
      _changed -> {:error, :draft_attachments_changed}
    end
  end

  @spec resolve_attachment_text(
          GenServer.server(),
          [DraftSnapshot.attachment()],
          [{DraftSnapshot.attachment(), String.t()}],
          non_neg_integer()
        ) :: {:ok, [{DraftSnapshot.attachment(), String.t()}]} | {:error, term()}
  defp resolve_attachment_text(_store, [], results, _bytes), do: {:ok, Enum.reverse(results)}

  defp resolve_attachment_text(store, [attachment | rest], results, bytes) do
    with {:ok, text} <- DraftAttachment.read_text(store, attachment),
         total = bytes + byte_size(text),
         true <- total <= 1_048_576 || {:error, :draft_attachments_too_large} do
      resolve_attachment_text(store, rest, [{attachment, text} | results], total)
    end
  end

  @doc """
  Saves the next draft revision without changing the conversation. Exact retries are idempotent.

  Pass `nil` to clear the draft at a new revision. A stale revision returns the current revision without writing.
  """
  @spec save_presentation(
          String.t(),
          draft_revision(),
          DraftSnapshot.t() | nil,
          String.t() | nil,
          keyword()
        ) ::
          {:ok, draft_revision()} | {:error, term()}
  def save_presentation(id, expected, draft, config_dir \\ nil, opts \\ [])
      when is_binary(id) and is_integer(expected) and expected >= 0 and is_list(opts) do
    write_presentation(id, config_dir, expected, draft, opts, :ordinary)
  end

  @doc "Commits an explicit attachment removal, confirming an interrupted rename before reporting success."
  @spec save_attachment_removal(
          String.t(),
          draft_revision(),
          DraftSnapshot.t() | nil,
          String.t() | nil,
          keyword()
        ) ::
          {:ok, draft_revision()} | {:error, term()}
  def save_attachment_removal(id, expected, draft, config_dir, opts) do
    write_presentation(id, config_dir, expected, draft, opts, :attach_draft)
  end

  @spec write_presentation(
          String.t(),
          String.t() | nil,
          draft_revision(),
          DraftSnapshot.t() | nil,
          keyword(),
          :ordinary | :attach_draft
        ) ::
          {:ok, draft_revision()} | {:error, term()}
  defp write_presentation(id, config_dir, expected, draft, opts, mode) do
    path = session_record_path(id, config_dir)

    with :ok <- validate_presentation_id(id),
         :ok <- validate_artifact_opts(opts),
         {:ok, encoded_draft} <- encode_draft(draft) do
      with_record_workflow(path, fn ->
        commit_presentation(path, id, expected, encoded_draft, opts, mode)
      end)
    end
  end

  @doc "Captures an explicit text snapshot and commits it with the exact composer revision."
  @spec attach_text(
          String.t(),
          draft_revision(),
          DraftSnapshot.t(),
          DraftAttachment.text_snapshot(),
          String.t() | nil,
          keyword()
        ) :: {:ok, draft_revision(), DraftSnapshot.attachment()} | {:error, term()}
  def attach_text(id, expected, %DraftSnapshot{} = draft, snapshot, config_dir, opts) do
    path = session_record_path(id, config_dir)

    with :ok <- validate_presentation_id(id),
         :ok <- validate_artifact_opts(opts) do
      with_record_workflow(path, fn ->
        attach_text_at_revision(path, id, expected, draft, snapshot, opts)
      end)
    end
  end

  @spec attach_text_at_revision(
          String.t(),
          String.t(),
          draft_revision(),
          DraftSnapshot.t(),
          DraftAttachment.text_snapshot(),
          keyword()
        ) :: {:ok, draft_revision(), DraftSnapshot.attachment()} | {:error, term()}
  defp attach_text_at_revision(path, id, expected, draft, snapshot, opts) do
    with {:ok, record, generation} <- read_record_for_write(path, id, opts),
         {:ok, {^expected, _draft}} <- decode_presentation(record),
         {:ok, store} <- ensure_artifact_store(id, opts),
         {:ok, attachment, pin} <- DraftAttachment.capture_text(store, snapshot) do
      updated = %{draft | attachments: [attachment | draft.attachments]}

      result =
        with {:ok, encoded} <- encode_draft(updated),
             {:ok, revision} <-
               save_presentation_revision(
                 path,
                 id,
                 {record, generation, expected},
                 expected,
                 encoded,
                 opts,
                 :attach_draft
               ) do
          {:ok, revision, attachment}
        end

      # An ambiguous rename leaves the candidate snapshot pin intact. Only the delivery pin is released here.
      _ = ArtifactStore.release(store, pin)
      result
    else
      {:ok, {revision, _draft}} -> {:error, {:stale_draft_revision, revision}}
      {:error, _reason} = error -> error
    end
  end

  @spec commit_presentation(
          String.t(),
          String.t(),
          draft_revision(),
          map() | nil,
          keyword(),
          :ordinary | :attach_draft
        ) ::
          {:ok, draft_revision()} | {:error, term()}
  defp commit_presentation(path, id, expected, draft, opts, mode) do
    with {:ok, previous, generation} <- read_record_for_write(path, id, opts),
         {:ok, {revision, _draft}} <- decode_presentation(previous) do
      save_presentation_revision(
        path,
        id,
        {previous, generation, revision},
        expected,
        draft,
        opts,
        mode
      )
    end
  end

  @spec save_presentation_revision(
          String.t(),
          String.t(),
          {map(), String.t() | nil, draft_revision()},
          draft_revision(),
          map() | nil,
          keyword(),
          :ordinary | :attach_draft
        ) :: {:ok, draft_revision()} | {:error, term()}
  defp save_presentation_revision(
         path,
         id,
         {record, generation, expected},
         expected,
         draft,
         opts,
         mode
       ) do
    revision = expected + 1

    with {:ok, record} <- editable_presentation_record(record, id),
         record = Map.put(record, "presentation", %{"revision" => revision, "draft" => draft}),
         {:ok, encoded} <- encode_record(record, id),
         :ok <- save_record(path, id, encoded, generation, opts, mode) do
      {:ok, revision}
    end
  end

  defp save_presentation_revision(
         _path,
         id,
         {%{"presentation" => %{"draft" => draft}} = record, generation, revision},
         expected,
         draft,
         opts,
         _mode
       )
       when revision == expected + 1 do
    with :ok <- reconcile_presentation_record(id, record, generation, opts), do: {:ok, revision}
  end

  defp save_presentation_revision(
         _path,
         _id,
         {_record, _generation, revision},
         _expected,
         _draft,
         _opts,
         _mode
       ),
       do: {:error, {:stale_draft_revision, revision}}

  @spec editable_presentation_record(map(), String.t()) ::
          {:ok, map()} | {:error, :legacy_import_required}
  defp editable_presentation_record(record, id) when map_size(record) == 0,
    do: {:ok, new_envelope(id, nil, nil)}

  defp editable_presentation_record(%{"version" => @envelope_version} = record, _id),
    do: {:ok, record}

  defp editable_presentation_record(%{"version" => version} = record, id)
       when version in [2, 3, 4, 5, @version],
       do: {:ok, new_envelope(id, record, nil)}

  defp editable_presentation_record(_record, _id), do: {:error, :legacy_import_required}

  @spec encode_draft(DraftSnapshot.t() | nil) :: {:ok, map() | nil} | {:error, term()}
  defp encode_draft(nil), do: {:ok, nil}
  defp encode_draft(%DraftSnapshot{} = draft), do: DraftSnapshot.encode(draft)

  @spec validate_presentation_id(String.t()) :: :ok | {:error, :invalid_session_id}
  defp validate_presentation_id(id) do
    if id not in ["", ".", ".."] and not String.contains?(id, ["/", "\\", <<0>>]) do
      :ok
    else
      {:error, :invalid_session_id}
    end
  end

  @spec decode_presentation(map()) :: {:ok, presentation()} | {:error, term()}
  defp decode_presentation(%{
         "version" => @envelope_version,
         "presentation" => %{"revision" => revision, "draft" => draft}
       })
       when is_integer(revision) and revision > 0 do
    case draft do
      nil -> {:ok, {revision, nil}}
      encoded -> with {:ok, draft} <- DraftSnapshot.decode(encoded), do: {:ok, {revision, draft}}
    end
  end

  defp decode_presentation(%{"presentation" => _invalid}), do: {:error, :invalid_draft_snapshot}

  defp decode_presentation(%{"version" => @envelope_version}),
    do: {:error, :invalid_draft_snapshot}

  defp decode_presentation(_record), do: {:ok, {0, nil}}

  @spec reconcile_presentation_record(String.t(), map(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  defp reconcile_presentation_record(_id, _record, nil, _opts), do: :ok

  defp reconcile_presentation_record(id, record, generation, opts) do
    references = snapshot_references(record)

    with {:ok, store} <- artifact_store_for_reconciliation(id, references, opts) do
      repair_snapshot_ownership(store, generation, references)
    end
  catch
    :exit, reason -> {:error, {:artifact_store_unavailable, reason}}
  end

  @spec session_record_path(String.t(), String.t() | nil) :: String.t()
  defp session_record_path(id, config_dir),
    do: config_dir |> sessions_dir() |> Path.join("#{id}.json") |> Path.expand()

  @spec with_record_workflow(String.t(), (-> result)) :: result | {:error, term()}
        when result: var
  defp with_record_workflow(path, operation) do
    case :global.trans({{__MODULE__, path}, self()}, operation, [node()], :infinity) do
      :aborted -> {:error, :session_record_lock_aborted}
      result -> result
    end
  end

  @spec save_record(
          String.t(),
          String.t(),
          {String.t(), [Reference.t()], String.t()},
          String.t() | nil,
          keyword(),
          :ordinary | :attach_draft | :admit_draft
        ) ::
          :ok | {:error, term()}
  defp save_record(
         path,
         id,
         {json, references, generation},
         previous_generation,
         opts,
         mode \\ :ordinary
       ) do
    with :ok <- ensure_private_dir(Path.dirname(path)),
         {:ok, store} <- pin_candidate(id, generation, references, opts) do
      case atomic_write_private_result(path, json, fault_injector(opts)) do
        {:ok, :durable} ->
          finish_committed_snapshot(id, store, generation, references)

        {:error, reason, :before_rename} ->
          release_failed_candidate(id, store, previous_generation, generation)
          {:error, reason}

        {:error, reason, :after_rename} when mode in [:admit_draft, :attach_draft] ->
          confirm_draft_commit(
            Path.dirname(path),
            {id, store, generation, references},
            mode,
            reason
          )

        {:error, reason, :after_rename} ->
          {:error, reason}
      end
    end
  end

  @spec confirm_draft_commit(
          String.t(),
          {String.t(), GenServer.server() | nil, String.t(), [Reference.t()]},
          :attach_draft | :admit_draft,
          term()
        ) :: :ok | {:error, term()}
  defp confirm_draft_commit(directory, {id, store, generation, references}, mode, reason) do
    case sync_directory(directory) do
      :ok -> finish_committed_snapshot(id, store, generation, references)
      {:error, sync_reason} -> {:error, {:draft_commit_uncertain, mode, reason, sync_reason}}
    end
  end

  @spec encode_snapshot(session_data(), map() | nil, map()) ::
          {:ok, {String.t(), [Reference.t()], String.t()}} | {:error, term()}
  defp encode_snapshot(data, presentation, previous) do
    conversation = carry_user_metadata(serialize(data), record_conversation(previous))

    record =
      case presentation do
        nil ->
          conversation

        presentation ->
          generation = conversation |> conversation_references() |> snapshot_generation()
          conversation = Map.put(conversation, "artifact_generation", generation)
          new_envelope(data.id, conversation, presentation)
      end

    encode_record(record, data.id)
  rescue
    error -> {:error, {:snapshot_encode_failed, Exception.message(error)}}
  end

  @spec carry_user_metadata(map(), map() | nil) :: map()
  defp carry_user_metadata(conversation, previous) do
    conversation
    |> carry_custom_title(previous)
    |> carry_archive_flag(previous)
  end

  @spec carry_archive_flag(map(), map() | nil) :: map()
  defp carry_archive_flag(conversation, %{"archived" => true}),
    do: Map.put(conversation, "archived", true)

  defp carry_archive_flag(conversation, _previous), do: conversation

  @spec carry_custom_title(map(), map() | nil) :: map()
  defp carry_custom_title(conversation, %{"custom_title" => title}) when is_binary(title),
    do: Map.put(conversation, "custom_title", title)

  defp carry_custom_title(conversation, _previous), do: conversation

  @spec stored_custom_title(map()) :: String.t() | nil
  defp stored_custom_title(%{"custom_title" => title}) when is_binary(title) do
    case normalize_title(title) do
      {:ok, normalized} -> normalized
      {:error, :invalid_session_title} -> nil
    end
  end

  defp stored_custom_title(_record), do: nil

  @spec encode_record(map(), String.t()) ::
          {:ok, {String.t(), [Reference.t()], String.t()}} | {:error, term()}
  defp encode_record(candidate, id) do
    references = snapshot_references(candidate)
    generation = snapshot_generation(references)
    candidate = Map.put(candidate, "artifact_generation", generation)
    json = JSON.encode!(candidate)

    with {:ok, encoded_record} <- decode_json(json),
         {:ok, _session, _generation, _references} <-
           validated_record_authority(encoded_record, id) do
      {:ok, {json, references, generation}}
    end
  rescue
    error -> {:error, {:snapshot_encode_failed, Exception.message(error)}}
  end

  @spec new_envelope(String.t(), map() | nil, map() | nil) :: map()
  defp new_envelope(id, conversation, presentation) do
    %{
      "version" => @envelope_version,
      "id" => id,
      "conversation" => conversation,
      "presentation" => presentation
    }
  end

  @spec snapshot_generation([Reference.t()]) :: String.t()
  defp snapshot_generation(references) do
    tokens =
      references
      |> Enum.map(& &1.token)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join("\n")

    :crypto.hash(:sha256, tokens) |> Base.encode16(case: :lower)
  end

  @spec snapshot_references(map()) :: [Reference.t()]
  defp snapshot_references(
         %{"version" => @envelope_version, "conversation" => conversation} = record
       ) do
    conversation_references =
      if is_map(conversation), do: conversation_references(conversation), else: []

    presentation_references =
      case decode_presentation(record) do
        {:ok, {_revision, %DraftSnapshot{} = draft}} -> DraftSnapshot.references(draft)
        _ -> []
      end

    (conversation_references ++ presentation_references)
    |> Enum.uniq()
    |> Enum.sort_by(& &1.token)
  end

  defp snapshot_references(conversation),
    do: conversation |> conversation_references() |> canonical_references()

  @spec conversation_references(map()) :: [Reference.t()]
  defp conversation_references(candidate) do
    transcript_messages =
      Map.get(candidate, "messages", []) ++
        Enum.flat_map(Map.get(candidate, "branches", []), fn branch -> branch["messages"] end)

    transcript_references =
      Enum.flat_map(transcript_messages, fn
        %{"type" => "tool_call", "output" => encoded} when is_map(encoded) ->
          case OutputCodec.decode(encoded) do
            {:ok, output} -> Output.references(output)
            {:error, _reason} -> []
          end

        _message ->
          []
      end)

    transcript_references ++
      ContinuationCodec.references(candidate["continuation"]) ++
      checklist_references(candidate["checklist"]) ++
      checklist_archive_references(candidate["checklist_archive"])
  end

  @spec checklist_references(term()) :: [Reference.t()]
  defp checklist_references(nil), do: []

  defp checklist_references(encoded) do
    case Checklist.decode(encoded) do
      {:ok, checklist} -> Checklist.references(checklist)
      {:error, :invalid_checklist} -> []
    end
  end

  @spec checklist_archive_references(term()) :: [Reference.t()]
  defp checklist_archive_references(nil), do: []

  defp checklist_archive_references(encoded) do
    case ChecklistArchive.decode(encoded) do
      {:ok, archive} -> ChecklistArchive.references(archive)
      {:error, :invalid_checklist_archive} -> []
    end
  end

  @spec canonical_references([Reference.t()]) :: [Reference.t()]
  defp canonical_references(references) do
    references |> Enum.uniq_by(& &1.token) |> Enum.sort_by(& &1.token)
  end

  @spec pin_candidate(String.t(), String.t(), [Reference.t()], keyword()) ::
          {:ok, GenServer.server() | nil} | {:error, term()}
  defp pin_candidate(id, generation, references, opts) do
    with {:ok, store} <- artifact_store_for_reconciliation(id, references, opts),
         :ok <- pin_snapshot(store, generation, references) do
      {:ok, store}
    end
  catch
    :exit, reason -> {:error, {:artifact_store_unavailable, reason}}
  end

  @spec pin_snapshot(GenServer.server() | nil, String.t(), [Reference.t()]) ::
          :ok | {:error, term()}
  defp pin_snapshot(_store, _generation, []), do: :ok

  defp pin_snapshot(store, generation, references),
    do: ArtifactStore.pin(store, {:snapshot, generation}, references)

  @spec finish_committed_snapshot(String.t(), GenServer.server() | nil, String.t(), [
          Reference.t()
        ]) :: :ok
  defp finish_committed_snapshot(id, store, generation, references) do
    result = repair_snapshot_ownership(store, generation, references)
    log_release_failure(id, generation, result)
  catch
    :exit, reason ->
      log_release_failure(id, generation, {:error, {:artifact_store_unavailable, reason}})
  end

  @spec repair_snapshot_ownership(GenServer.server() | nil, String.t() | nil, [Reference.t()]) ::
          :ok | {:error, term()}
  defp repair_snapshot_ownership(nil, _generation, []), do: :ok

  defp repair_snapshot_ownership(store, generation, []) do
    ArtifactStore.reconcile_snapshot_pins(store, generation)
  end

  defp repair_snapshot_ownership(store, generation, references) do
    with :ok <-
           ArtifactStore.pin(store, {:snapshot, generation}, references, transfer_delivery: true) do
      ArtifactStore.reconcile_snapshot_pins(store, generation)
    end
  end

  @spec log_release_failure(String.t(), String.t(), :ok | {:error, term()}) :: :ok
  defp log_release_failure(_id, _generation, :ok), do: :ok

  defp log_release_failure(id, generation, {:error, reason}) do
    Minga.Log.warning(
      :agent,
      "[SessionStore] retained ownership leak for #{id} generation #{generation}: #{inspect(reason)}"
    )

    :ok
  end

  @spec release_failed_candidate(
          String.t(),
          GenServer.server() | nil,
          String.t() | nil,
          String.t()
        ) :: :ok
  defp release_failed_candidate(_id, nil, _previous, _candidate), do: :ok
  defp release_failed_candidate(_id, _store, generation, generation), do: :ok

  defp release_failed_candidate(id, store, _previous, candidate) do
    result = ArtifactStore.release(store, {:snapshot, candidate})
    log_release_failure(id, candidate, result)
  catch
    :exit, reason ->
      log_release_failure(id, candidate, {:error, {:artifact_store_unavailable, reason}})
  end

  @spec ensure_artifact_store(String.t(), keyword()) ::
          {:ok, GenServer.server()} | {:error, term()}
  defp ensure_artifact_store(id, opts) do
    case Keyword.fetch(opts, :artifact_runtime) do
      {:ok, runtime} -> ArtifactStores.ensure_record(id, runtime)
      :error -> ArtifactStores.ensure_record(id)
    end
  end

  @spec validate_artifact_opts(term()) :: :ok | {:error, :invalid_artifact_options}
  defp validate_artifact_opts(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:artifact_runtime, :fault_injector] == [] do
      :ok
    else
      {:error, :invalid_artifact_options}
    end
  end

  @spec fault_injector(keyword()) :: FaultInjector.t()
  defp fault_injector(opts), do: Keyword.get(opts, :fault_injector)

  @spec read_record_for_write(String.t(), String.t(), keyword()) ::
          {:ok, map(), String.t() | nil} | {:error, term()}
  defp read_record_for_write(path, id, opts) do
    case read_durable_record(path, opts) do
      {:ok, data} ->
        with {:ok, generation} <- previous_record_authority(data, id), do: {:ok, data, generation}

      {:error, :enoent} ->
        {:ok, %{}, nil}

      {:error, _reason} = error ->
        error
    end
  end

  @spec previous_record_authority(map(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  defp previous_record_authority(data, id) do
    case Map.get(data, "version") do
      version when version in [nil, 1] ->
        with {:ok, {0, nil}} <- decode_presentation(data),
             true <- valid_legacy_authority?(data, id),
             %{} <- deserialize_legacy(data) do
          {:ok, nil}
        else
          {:error, _reason} = error -> error
          _invalid -> {:error, :invalid_session_record}
        end

      _version ->
        with {:ok, _session, generation, _references} <- validated_record_authority(data, id),
             do: {:ok, generation}
    end
  rescue
    _error -> {:error, :invalid_session_record}
  end

  @spec valid_legacy_authority?(map(), String.t()) :: boolean()
  defp valid_legacy_authority?(
         %{"id" => id, "timestamp" => timestamp, "messages" => messages} = data,
         id
       ) do
    non_empty_string?(id) and not Map.has_key?(data, "artifact_generation") and
      valid_timestamp?(timestamp) and valid_legacy_messages?(messages) and
      valid_legacy_branches?(Map.get(data, "branches", []))
  end

  defp valid_legacy_authority?(_data, _id), do: false

  @spec valid_legacy_messages?(term()) :: boolean()
  defp valid_legacy_messages?(messages) when is_list(messages),
    do: Enum.all?(messages, &valid_snapshot_message?(&1, @legacy_version))

  defp valid_legacy_messages?(_messages), do: false

  @spec valid_legacy_branches?(term()) :: boolean()
  defp valid_legacy_branches?(nil), do: true

  defp valid_legacy_branches?(branches) when is_list(branches) do
    Enum.all?(branches, fn
      %{"name" => name, "created_at" => created_at, "messages" => messages} ->
        non_empty_string?(name) and valid_timestamp?(created_at) and
          valid_legacy_messages?(messages)

      _invalid ->
        false
    end)
  end

  defp valid_legacy_branches?(_branches), do: false

  @spec read_durable_record(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp read_durable_record(path, opts) do
    with :ok <- FaultInjector.run(fault_injector(opts), :before_session_snapshot_recovery_sync),
         :ok <- sync_existing_directory(Path.dirname(path)),
         {:ok, json} <- File.read(path),
         {:ok, data} when is_map(data) <- decode_json(json) do
      {:ok, data}
    else
      {:ok, _other} -> {:error, :invalid_session_record}
      {:error, _reason} = error -> error
    end
  end

  @spec validated_record_authority(map(), String.t()) ::
          {:ok, session_data() | :no_conversation, String.t() | nil, [Reference.t()]}
          | {:error, term()}
  defp validated_record_authority(data, id) do
    with {:ok, _presentation} <- decode_presentation(data),
         {:ok, session} <- decode_record_conversation(data, id),
         {:ok, generation, references} <- artifact_authority(data) do
      {:ok, session, generation, references}
    end
  rescue
    _error -> {:error, :invalid_session_record}
  end

  @spec decode_record_conversation(map(), String.t()) ::
          {:ok, session_data() | :no_conversation} | {:error, term()}
  defp decode_record_conversation(
         %{"version" => @envelope_version, "id" => id, "conversation" => conversation} = record,
         id
       )
       when map_size(record) == 5 do
    if non_empty_string?(id) and valid_generation?(record["artifact_generation"]) do
      decode_envelope_conversation(conversation, id)
    else
      {:error, :invalid_session_record}
    end
  end

  defp decode_record_conversation(%{"version" => @envelope_version}, _id),
    do: {:error, :invalid_session_record}

  defp decode_record_conversation(record, id), do: load_versioned_record(record, id)

  @spec decode_envelope_conversation(term(), String.t()) ::
          {:ok, session_data() | :no_conversation} | {:error, term()}
  defp decode_envelope_conversation(nil, _id), do: {:ok, :no_conversation}

  defp decode_envelope_conversation(%{"presentation" => _draft}, _id),
    do: {:error, :invalid_draft_snapshot}

  defp decode_envelope_conversation(conversation, id) when is_map(conversation) do
    with {:ok, session} <- load_versioned_record(conversation, id),
         {:ok, _generation, _references} <- artifact_authority(conversation) do
      {:ok, session}
    end
  end

  defp decode_envelope_conversation(_invalid, _id), do: {:error, :invalid_session_record}

  @spec artifact_authority(map()) ::
          {:ok, String.t() | nil, [Reference.t()]} | {:error, :invalid_session_record}
  defp artifact_authority(%{"version" => version, "artifact_generation" => generation} = data)
       when version in [3, 5, @version, @envelope_version] do
    references = snapshot_references(data)

    if generation == snapshot_generation(references),
      do: {:ok, generation, references},
      else: {:error, :invalid_session_record}
  end

  defp artifact_authority(%{"version" => version} = data) when version in [2, 3, 4] do
    case {Map.has_key?(data, "artifact_generation"), snapshot_references(data)} do
      {false, []} -> {:ok, nil, []}
      _other -> {:error, :invalid_session_record}
    end
  end

  @spec valid_generation?(term()) :: boolean()
  defp valid_generation?(generation) when is_binary(generation),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, generation)

  defp valid_generation?(_generation), do: false

  @doc """
  Establishes manager-owned remote session identity.

  Existing canonical identity wins over legacy transcript identity and the candidate. A new identity is persisted before it is returned.
  """
  @spec establish_remote_token(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def establish_remote_token(session_id, candidate, config_dir \\ nil)
      when is_binary(session_id) and is_binary(candidate) do
    path = Path.join(remote_tokens_dir(config_dir), "#{session_id}.json")

    case read_remote_token(path, {:error, :invalid_remote_token_record}) do
      {:ok, token} -> {:ok, token}
      :missing -> establish_missing_remote_token(path, session_id, candidate, config_dir)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec establish_missing_remote_token(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  defp establish_missing_remote_token(path, session_id, candidate, config_dir) do
    with {:ok, token} <- new_remote_token(session_id, candidate, config_dir),
         :ok <- atomic_write_private(path, encode_remote_token(token)) do
      {:ok, token}
    end
  end

  @spec new_remote_token(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  defp new_remote_token(session_id, candidate, config_dir) do
    case load_legacy_remote_token(session_id, config_dir) do
      {:ok, token} -> {:ok, token}
      :missing -> {:ok, candidate}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec remote_tokens_dir(String.t() | nil) :: String.t()
  defp remote_tokens_dir(config_dir) do
    Path.join(sessions_dir(config_dir), ".remote_tokens")
  end

  @spec load_legacy_remote_token(String.t(), String.t() | nil) :: remote_token_result()
  defp load_legacy_remote_token(session_id, config_dir) do
    path = Path.join(sessions_dir(config_dir), "#{session_id}.json")
    read_remote_token(path, :missing)
  end

  @spec read_remote_token(String.t(), :missing | {:error, term()}) :: remote_token_result()
  defp read_remote_token(path, missing_record) do
    with {:ok, json} <- File.read(path),
         {:ok, data} when is_map(data) <- decode_json(json) do
      case record_conversation(data) do
        %{"remote_token" => token} when is_binary(token) -> {:ok, token}
        _ -> missing_record
      end
    else
      {:ok, _other} -> missing_record
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encode_remote_token(String.t()) :: String.t()
  defp encode_remote_token(token), do: JSON.encode!(%{"remote_token" => token})

  @doc """
  Loads a versioned, lossless session snapshot.

  Legacy display-only records are rejected until the caller explicitly uses
  `load_legacy/2`; unknown future versions are never guessed.
  """
  @spec load(String.t(), String.t() | nil) :: {:ok, session_data()} | {:error, term()}
  def load(session_id, config_dir \\ nil) when is_binary(session_id),
    do: load(session_id, config_dir, [])

  @doc "Loads a session and reconciles retained snapshot pin generations."
  @spec load(String.t(), String.t() | nil, keyword()) ::
          {:ok, session_data()} | {:error, term()}
  def load(session_id, config_dir, opts) when is_binary(session_id) and is_list(opts) do
    case load_recoverable(session_id, config_dir, opts) do
      {:ok, :draft_only} -> {:error, :enoent}
      result -> result
    end
  end

  @doc "Opens a saved record, distinguishing a draft-only record from a missing conversation."
  @spec load_recoverable(String.t(), String.t() | nil, keyword()) ::
          {:ok, session_data() | :draft_only} | {:error, term()}
  def load_recoverable(session_id, config_dir \\ nil, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    path = session_record_path(session_id, config_dir)

    with :ok <- validate_presentation_id(session_id),
         :ok <- validate_artifact_opts(opts) do
      with_record_workflow(path, fn -> load_record(path, session_id, opts) end)
    end
  end

  @spec load_record(String.t(), String.t(), keyword()) ::
          {:ok, session_data() | :draft_only} | {:error, term()}
  defp load_record(path, id, opts) do
    with {:ok, data} <- read_durable_record(path, opts),
         {:ok, session, generation, references} <- validated_record_authority(data, id),
         {:ok, store} <- artifact_store_for_reconciliation(id, references, opts),
         :ok <- repair_snapshot_ownership(store, generation, references) do
      recoverable_record(session, data)
    end
  catch
    :exit, reason -> {:error, {:artifact_store_unavailable, reason}}
  end

  @spec recoverable_record(session_data() | :no_conversation, map()) ::
          {:ok, session_data() | :draft_only} | {:error, :enoent}
  defp recoverable_record(:no_conversation, %{"presentation" => %{"draft" => draft}})
       when is_map(draft),
       do: {:ok, :draft_only}

  defp recoverable_record(:no_conversation, _data), do: {:error, :enoent}
  defp recoverable_record(session, _data), do: {:ok, session}

  @spec artifact_store_for_reconciliation(String.t(), [Reference.t()], keyword()) ::
          {:ok, GenServer.server() | nil} | {:error, term()}
  defp artifact_store_for_reconciliation(session_id, [_reference | _rest], opts),
    do: ensure_artifact_store(session_id, opts)

  defp artifact_store_for_reconciliation(session_id, [], opts) do
    runtime = Keyword.get(opts, :artifact_runtime, ArtifactStores.default_runtime())

    case Registry.lookup(runtime.registry, session_id) do
      [{store, _value}] ->
        {:ok, store}

      [] ->
        namespace = Reference.namespace(session_id)

        case ArtifactQuota.namespace_registered?(runtime.quota, runtime.root, namespace) do
          {:ok, true} -> ensure_artifact_store(session_id, opts)
          {:ok, false} -> {:ok, nil}
          {:error, _reason} = error -> error
        end
    end
  rescue
    ArgumentError -> {:error, :artifact_runtime_unavailable}
  catch
    :exit, reason -> {:error, {:artifact_runtime_unavailable, reason}}
  end

  @spec load_versioned_record(map(), String.t()) :: {:ok, session_data()} | {:error, term()}
  defp load_versioned_record(%{"version" => version} = data, session_id)
       when version in [2, 3, 4, 5, @version] do
    with :ok <- validate_versioned_record(data, session_id),
         {:ok, session} <- deserialize(data) do
      restore_selection_data(version, data, session)
    end
  end

  defp load_versioned_record(%{"version" => version}, _session_id)
       when version not in [nil, 1, 2, 3, 4, 5, @version],
       do: {:error, {:unknown_session_version, version}}

  defp load_versioned_record(_data, _session_id), do: {:error, :legacy_import_required}

  @doc "Reads an unversioned or version-one display-only record for explicit one-way import."
  @spec load_legacy(String.t(), String.t() | nil) :: {:ok, session_data()} | {:error, term()}
  def load_legacy(session_id, config_dir \\ nil) when is_binary(session_id) do
    with {:ok, data} <- read_record(session_id, config_dir) do
      case data["version"] do
        version when version in [nil, 1] ->
          legacy = deserialize_legacy(data)
          {:ok, Map.put(legacy, :continuation, Continuation.import_legacy(legacy.messages))}

        _version ->
          {:error, :not_legacy_session}
      end
    end
  rescue
    _error -> {:error, :invalid_session_record}
  end

  @spec read_record(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  defp read_record(session_id, config_dir) do
    path = Path.join(sessions_dir(config_dir), "#{session_id}.json")

    with {:ok, json} <- File.read(path),
         {:ok, data} when is_map(data) <- decode_json(json) do
      {:ok, data}
    else
      {:ok, _other} -> {:error, :invalid_session_record}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_versioned_record(map(), String.t()) :: :ok | {:error, atom()}
  defp validate_versioned_record(data, requested_id) do
    version = data["version"]
    schema = snapshot_schema(data)

    with true <- data["id"] == requested_id,
         true <- non_empty_string?(data["id"]),
         true <- valid_timestamp?(data["timestamp"]),
         true <- valid_timestamp?(data["last_message_at"]),
         true <- non_empty_string?(data["title"]),
         true <- non_empty_string?(data["model_name"]),
         true <- non_empty_string?(data["provider_name"]),
         true <- valid_model_selection_field?(data),
         true <-
           is_list(data["messages"]) and
             Enum.all?(data["messages"], &valid_snapshot_message?(&1, schema)),
         true <- valid_v2_message_ids?(data["message_ids"], data["messages"]),
         true <- valid_snapshot_branches?(data["branches"], schema),
         true <- valid_v2_pins?(data["pinned_ids"], data["message_ids"], data["branches"]),
         true <- valid_v2_usage?(data["usage"]),
         true <- is_nil(data["memory"]) or is_binary(data["memory"]),
         true <- is_map(data["continuation"]),
         true <- valid_record_generation?(data, version) do
      :ok
    else
      _invalid -> {:error, :invalid_session_record}
    end
  end

  @spec snapshot_schema(map()) :: snapshot_schema()
  defp snapshot_schema(%{"version" => 3, "artifact_generation" => _generation}), do: :retention_v3
  defp snapshot_schema(%{"version" => 3}), do: :model_v3
  defp snapshot_schema(%{"version" => version}) when version in [2, 4, 5, @version], do: version

  @spec non_empty_string?(term()) :: boolean()
  defp non_empty_string?(value), do: is_binary(value) and value != ""

  @spec valid_model_selection_field?(map()) :: boolean()
  defp valid_model_selection_field?(%{"version" => 2}), do: true

  defp valid_model_selection_field?(
         %{"version" => 3, "artifact_generation" => _generation} = data
       ),
       do:
         not Map.has_key?(data, "model_selection") and not Map.has_key?(data, "selection_intent")

  defp valid_model_selection_field?(%{"version" => version} = data)
       when version in [3, 4, 5, @version] do
    is_map(data["model_selection"]) or is_map(data["selection_intent"])
  end

  defp valid_model_selection_field?(_data), do: false

  @spec valid_timestamp?(term()) :: boolean()
  defp valid_timestamp?(value) when is_binary(value) do
    match?({:ok, _, _}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false

  @spec valid_snapshot_message?(term(), snapshot_schema()) :: boolean()
  defp valid_snapshot_message?(%{"type" => "user", "text" => text} = message, _version)
       when is_binary(text) do
    case Map.get(message, "attachments", []) do
      attachments when is_list(attachments) -> Enum.all?(attachments, &valid_attachment?/1)
      _invalid -> false
    end
  end

  defp valid_snapshot_message?(
         %{"type" => "thinking", "text" => text, "collapsed" => collapsed},
         _version
       ),
       do: is_binary(text) and is_boolean(collapsed)

  defp valid_snapshot_message?(%{"type" => "assistant", "text" => text}, _version)
       when is_binary(text),
       do: true

  defp valid_snapshot_message?(%{"type" => "tool_call"} = message, version) do
    non_empty_string?(message["id"]) and non_empty_string?(message["name"]) and
      is_map(message["args"]) and valid_tool_terminal?(message, version) and
      (is_nil(message["result"]) or is_binary(message["result"])) and
      is_boolean(message["is_error"]) and is_boolean(message["collapsed"]) and
      valid_persisted_output?(message, version)
  end

  defp valid_snapshot_message?(
         %{"type" => "system", "text" => text, "level" => level},
         _version
       ),
       do: is_binary(text) and level in ["info", "error"]

  defp valid_snapshot_message?(%{"type" => "usage", "data" => usage}, _version),
    do: valid_v2_usage?(usage)

  defp valid_snapshot_message?(_message, _version), do: false

  @spec valid_tool_terminal?(map(), snapshot_schema()) :: boolean()
  defp valid_tool_terminal?(message, @version) do
    valid_tool_reason?(message["status"], Map.fetch(message, "terminal_reason")) and
      valid_tool_error_flag?(message["status"], message["is_error"]) and
      valid_tool_duration?(message["status"], message["terminal_reason"], message["duration_ms"])
  end

  defp valid_tool_terminal?(message, _legacy),
    do:
      message["status"] in ["running", "complete", "error"] and is_nil(message["terminal_reason"])

  defp valid_tool_reason?("error", {:ok, "approval_timeout"}), do: true

  defp valid_tool_reason?(status, {:ok, nil})
       when status in ["running", "complete", "denied", "cancelled", "error"], do: true

  defp valid_tool_reason?(_status, _reason), do: false

  defp valid_tool_error_flag?(status, false) when status in ["running", "complete"], do: true

  defp valid_tool_error_flag?(status, true) when status in ["denied", "cancelled", "error"],
    do: true

  defp valid_tool_error_flag?(_status, _flag), do: false

  defp valid_tool_duration?("denied", nil, nil), do: true
  defp valid_tool_duration?("denied", nil, _duration), do: false
  defp valid_tool_duration?("error", "approval_timeout", nil), do: true
  defp valid_tool_duration?("error", "approval_timeout", _duration), do: false
  defp valid_tool_duration?(_status, _reason, nil), do: true

  defp valid_tool_duration?(_status, _reason, duration),
    do: is_integer(duration) and duration >= 0

  @spec valid_persisted_output?(map(), snapshot_schema()) :: boolean()
  defp valid_persisted_output?(message, schema) when schema in [@legacy_version, 4, :model_v3],
    do: not Map.has_key?(message, "output")

  defp valid_persisted_output?(%{"output" => nil}, schema)
       when schema in [:retention_v3, 5, @version],
       do: true

  defp valid_persisted_output?(%{"output" => encoded}, schema)
       when schema in [:retention_v3, 5, @version] and is_map(encoded),
       do: match?({:ok, %Output{}}, OutputCodec.decode(encoded))

  defp valid_persisted_output?(_message, _version), do: false

  @spec valid_attachment?(term()) :: boolean()
  defp valid_attachment?(%{"filename" => filename, "size_kb" => size_kb}),
    do: is_binary(filename) and is_integer(size_kb) and size_kb >= 0

  defp valid_attachment?(_attachment), do: false

  @spec valid_v2_message_ids?(term(), [term()]) :: boolean()
  defp valid_v2_message_ids?(ids, messages) when is_list(ids) do
    length(ids) == length(messages) and Enum.all?(ids, &(is_integer(&1) and &1 > 0)) and
      Enum.uniq(ids) == ids
  end

  defp valid_v2_message_ids?(_ids, _messages), do: false

  @spec valid_v2_pins?(term(), term(), term()) :: boolean()
  defp valid_v2_pins?(pins, ids, branches)
       when is_list(pins) and is_list(ids) and is_list(branches) do
    branch_ids =
      Enum.flat_map(branches, fn
        %{"message_ids" => branch_message_ids} when is_list(branch_message_ids) ->
          branch_message_ids

        _branch ->
          []
      end)

    valid_ids = MapSet.new(ids ++ branch_ids)
    Enum.all?(pins, &(is_integer(&1) and &1 > 0 and MapSet.member?(valid_ids, &1)))
  end

  defp valid_v2_pins?(_pins, _ids, _branches), do: false

  @spec valid_snapshot_branches?(term(), snapshot_schema()) :: boolean()
  defp valid_snapshot_branches?(branches, version) when is_list(branches) do
    Enum.all?(branches, fn
      %{"name" => name, "messages" => messages, "message_ids" => ids, "created_at" => created_at} ->
        non_empty_string?(name) and is_list(messages) and
          Enum.all?(messages, &valid_snapshot_message?(&1, version)) and is_list(ids) and
          length(ids) == length(messages) and Enum.all?(ids, &(is_integer(&1) and &1 > 0)) and
          length(Enum.uniq(ids)) == length(ids) and valid_timestamp?(created_at)

      _branch ->
        false
    end)
  end

  defp valid_snapshot_branches?(_branches, _version), do: false

  @spec valid_record_generation?(map(), pos_integer()) :: boolean()
  defp valid_record_generation?(data, version) when version in [@legacy_version, 4],
    do: not Map.has_key?(data, "artifact_generation")

  defp valid_record_generation?(data, 3) do
    case Map.fetch(data, "artifact_generation") do
      {:ok, generation} -> valid_generation?(generation)
      :error -> true
    end
  end

  defp valid_record_generation?(data, version) when version in [5, @version],
    do: valid_generation?(data["artifact_generation"])

  @spec valid_v2_usage?(term()) :: boolean()
  defp valid_v2_usage?(usage) when is_map(usage) do
    Enum.all?(["input", "output", "cache_read", "cache_write"], fn key ->
      is_integer(usage[key]) and usage[key] >= 0
    end) and is_number(usage["cost"]) and usage["cost"] >= 0
  end

  defp valid_v2_usage?(_usage), do: false

  @doc """
  Lists all saved sessions as metadata (without full messages).

  Returns sessions sorted by last message timestamp, most recent first.
  """
  @spec list(String.t() | nil) :: [session_meta()]
  def list(config_dir \\ nil) do
    config_dir
    |> list_records(fn record, _path -> conversation_meta(record_conversation(record)) end)
    |> Enum.sort_by(& &1.last_message_at, :desc)
  end

  @doc "Lists conversations and non-empty draft-only records without exposing unsent input."
  @spec list_recoverable(String.t() | nil) :: [recovery_entry()]
  def list_recoverable(config_dir \\ nil) do
    config_dir
    |> list_records(&recovery_entry/2)
    |> Enum.sort_by(&recovery_timestamp/1, :desc)
  end

  @spec list_records(String.t() | nil, (map(), String.t() -> item | nil)) :: [item]
        when item: term()
  defp list_records(config_dir, project) do
    dir = sessions_dir(config_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reject(&String.ends_with?(&1, ".tmp"))
        |> Enum.map(&project_listed_record(Path.join(dir, &1), project))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  @spec project_listed_record(String.t(), (map(), String.t() -> item | nil)) :: item | nil
        when item: term()
  defp project_listed_record(path, project) do
    with {:ok, json} <- File.read(path),
         {:ok, record} when is_map(record) <- decode_json(json) do
      project.(record, path)
    else
      _ -> nil
    end
  end

  @spec ensure_private_dir(String.t()) :: :ok | {:error, term()}
  defp ensure_private_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> File.chmod(dir, 0o700)
      {:error, _reason} = error -> error
    end
  end

  @spec write_private_file(String.t(), String.t()) :: :ok | {:error, term()}
  defp write_private_file(path, contents) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw]) do
      {:ok, io} ->
        result =
          with :ok <- :file.write(io, contents),
               :ok <- File.chmod(path, 0o600) do
            :file.sync(io)
          end

        _closed = :file.close(io)

        case result do
          :ok ->
            :ok

          {:error, _reason} = error ->
            File.rm(path)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec atomic_write_private(String.t(), String.t()) :: :ok | {:error, term()}
  defp atomic_write_private(path, contents) do
    case atomic_write_private_result(path, contents, nil) do
      {:ok, :durable} -> :ok
      {:error, reason, _phase} -> {:error, reason}
    end
  end

  @spec atomic_write_private_result(String.t(), String.t(), FaultInjector.t()) ::
          {:ok, :durable} | {:error, term(), :before_rename | :after_rename}
  defp atomic_write_private_result(path, contents, fault_injector) do
    tmp_path = path <> ".tmp"
    directory = Path.dirname(path)

    before_rename =
      with :ok <- ensure_private_dir(directory),
           :ok <- write_private_file(tmp_path, contents),
           :ok <- FaultInjector.run(fault_injector, :before_session_snapshot_rename),
           :ok <- File.rename(tmp_path, path) do
        :renamed
      end

    case before_rename do
      :renamed ->
        with :ok <- FaultInjector.run(fault_injector, :after_session_snapshot_rename),
             :ok <- sync_directory(directory) do
          {:ok, :durable}
        else
          {:error, reason} -> {:error, reason, :after_rename}
        end

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason, :before_rename}
    end
  end

  @spec sync_directory(String.t()) :: :ok | {:error, term()}
  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, io} ->
        result = :file.sync(io)
        _closed = :file.close(io)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Durably deletes a transcript before explicitly dropping its retained artifact record."
  @spec delete(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def delete(session_id, config_dir \\ nil, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    path = session_record_path(session_id, config_dir)

    with :ok <- validate_artifact_opts(opts) do
      with_record_workflow(path, fn -> delete_record(path, session_id, opts) end)
    end
  end

  @spec delete_record(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defp delete_record(path, id, opts) do
    with :ok <- remove_session_record(path) do
      delete_artifact_record(id, opts)
    end
  end

  @spec remove_session_record(String.t()) :: :ok | {:error, term()}
  defp remove_session_record(path) do
    case File.rm(path) do
      :ok -> sync_directory(Path.dirname(path))
      {:error, :enoent} -> sync_existing_directory(Path.dirname(path))
      {:error, _reason} = error -> error
    end
  end

  @spec sync_existing_directory(String.t()) :: :ok | {:error, term()}
  defp sync_existing_directory(path) do
    case sync_directory(path) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  @spec delete_artifact_record(String.t(), keyword()) :: :ok | {:error, term()}
  defp delete_artifact_record(id, opts) do
    case Keyword.fetch(opts, :artifact_runtime) do
      {:ok, runtime} -> ArtifactStores.delete_record(id, runtime)
      :error -> ArtifactStores.delete_record(id)
    end
  end

  @doc "Deletes saved conversations and their artifacts, leaving draft-only records intact."
  @spec clear_all(String.t() | nil, keyword()) :: :ok
  def clear_all(config_dir \\ nil, opts \\ []) when is_list(opts) do
    dir = sessions_dir(config_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.each(&clear_history_entry(&1, dir, opts))

      {:error, _reason} ->
        :ok
    end
  end

  @spec clear_history_entry(String.t(), String.t(), keyword()) :: :ok
  defp clear_history_entry(file, dir, opts) do
    path = Path.join(dir, file) |> Path.expand()
    id = String.trim_trailing(file, ".json")

    result =
      with :ok <- validate_artifact_opts(opts) do
        with_record_workflow(path, fn -> clear_history_record(path, id, opts) end)
      end

    log_delete_failure(id, result)
  end

  @spec clear_history_record(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defp clear_history_record(path, id, opts) do
    case read_durable_record(path, opts) do
      {:ok, %{"version" => @envelope_version, "conversation" => nil}} -> :ok
      {:ok, _conversation_record} -> delete_record(path, id, opts)
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Prunes session transcripts older than `days` days.

  Returns the number durably removed before their artifact records were
  explicitly dropped. Durable remote identities and records with an unsent draft are retained.
  """
  @spec prune(non_neg_integer(), String.t() | nil, keyword()) :: non_neg_integer()
  def prune(days, config_dir \\ nil, opts \\ [])
      when is_integer(days) and days > 0 and is_list(opts) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    cutoff_str = DateTime.to_iso8601(cutoff)

    list(config_dir)
    |> Enum.filter(fn meta -> meta.timestamp < cutoff_str end)
    |> Enum.count(fn meta ->
      result = prune_one(meta.id, config_dir, cutoff_str, opts)
      if result != :keep, do: log_delete_failure(meta.id, result)
      result == :ok
    end)
  end

  @spec prune_one(String.t(), String.t() | nil, String.t(), keyword()) ::
          :ok | :keep | {:error, term()}
  defp prune_one(id, config_dir, cutoff, opts) do
    path = session_record_path(id, config_dir)

    with :ok <- validate_artifact_opts(opts) do
      with_record_workflow(path, fn -> prune_record(path, id, cutoff, opts) end)
    end
  end

  @spec prune_record(String.t(), String.t(), String.t(), keyword()) ::
          :ok | :keep | {:error, term()}
  defp prune_record(path, id, cutoff, opts) do
    with {:ok, record, _generation} <- read_record_for_write(path, id, opts),
         {:ok, {_revision, nil}} <- decode_presentation(record),
         %{"timestamp" => timestamp} when timestamp < cutoff <- record_conversation(record) do
      delete_record(path, id, opts)
    else
      {:error, _reason} = error -> error
      _ -> :keep
    end
  end

  @spec log_delete_failure(String.t(), :ok | {:error, term()}) :: :ok
  defp log_delete_failure(_id, :ok), do: :ok

  defp log_delete_failure(id, {:error, reason}) do
    Minga.Log.warning(
      :agent,
      "[SessionStore] explicit transcript/artifact deletion for #{id} failed: #{inspect(reason)}"
    )

    :ok
  end

  # ── Private: serialization ─────────────────────────────────────────────────

  @spec serialize(session_data()) :: map()
  defp serialize(data) do
    messages = Map.get(data, :messages, [])
    message_ids = Map.get(data, :message_ids) || default_message_ids(messages)
    timestamp = Map.get(data, :timestamp) || DateTime.to_iso8601(DateTime.utc_now())

    %{
      "version" => @version,
      "id" => data.id,
      "timestamp" => timestamp,
      "last_message_at" => Map.get(data, :last_message_at, timestamp),
      "title" => Map.get(data, :title) || title_from_messages(messages),
      "model_name" => data.model_name,
      "provider_name" => Map.get(data, :provider_name, "unknown"),
      "model_selection" => serialize_model_selection(Map.get(data, :model_selection)),
      "selection_intent" =>
        Map.get(data, :selection_intent, %{
          "model" => data.model_name,
          "provider" => Map.get(data, :provider_name, "unknown")
        }),
      "messages" => Enum.map(messages, &serialize_message/1),
      "message_ids" => message_ids,
      "pinned_ids" => serialize_pinned_ids(Map.get(data, :pinned_ids)),
      "usage" => serialize_usage(data.usage),
      "branches" => Enum.map(Map.get(data, :branches, []), &serialize_branch/1),
      "memory" => Map.get(data, :memory),
      "continuation" => ContinuationCodec.encode(data.continuation)
    }
    |> put_checklist(Map.get(data, :checklist))
    |> put_checklist_archive(Map.get(data, :checklist_archive))
  end

  @spec put_checklist(map(), Checklist.t() | nil) :: map()
  defp put_checklist(data, nil), do: data
  defp put_checklist(data, checklist), do: Map.put(data, "checklist", Checklist.encode(checklist))

  @spec put_checklist_archive(map(), ChecklistArchive.t() | nil) :: map()
  defp put_checklist_archive(data, nil), do: data

  defp put_checklist_archive(data, archive) do
    case ChecklistArchive.encode(archive) do
      nil -> data
      encoded -> Map.put(data, "checklist_archive", encoded)
    end
  end

  @spec serialize_model_selection(ModelSelection.t() | nil) :: map() | nil
  defp serialize_model_selection(%ModelSelection{} = selection),
    do: ModelSelection.encode(selection)

  defp serialize_model_selection(nil), do: nil

  @spec default_message_ids([term()]) :: [pos_integer()]
  defp default_message_ids(messages) when messages == [], do: []
  defp default_message_ids(messages), do: Enum.to_list(1..length(messages))

  @spec serialize_message(MingaAgent.Message.t()) :: map()
  defp serialize_message({:user, text, attachments}) do
    %{"type" => "user", "text" => text, "attachments" => attachments}
  end

  defp serialize_message({:user, text}), do: %{"type" => "user", "text" => text}
  defp serialize_message({:assistant, text}), do: %{"type" => "assistant", "text" => text}

  defp serialize_message({:thinking, text, collapsed}) do
    %{"type" => "thinking", "text" => text, "collapsed" => collapsed}
  end

  defp serialize_message({:tool_call, tc}) do
    %{
      "type" => "tool_call",
      "id" => tc.id,
      "name" => tc.name,
      "args" => tc.args,
      "status" => Atom.to_string(tc.status),
      "terminal_reason" => serialize_terminal_reason(tc.terminal_reason),
      "result" => tc.result,
      "output" => serialize_output(tc.output),
      "is_error" => tc.is_error,
      "collapsed" => tc.collapsed,
      "auto_approved_scope" => serialize_auto_approved_scope(tc.auto_approved_scope),
      "duration_ms" => tc.duration_ms,
      "preview" => serialize_tool_preview(tc.preview)
    }
  end

  defp serialize_message({:system, text, level}) do
    %{"type" => "system", "text" => text, "level" => Atom.to_string(level)}
  end

  defp serialize_message({:usage, %MingaAgent.TurnUsage{} = usage}),
    do: %{"type" => "usage", "data" => serialize_usage(usage)}

  defp serialize_terminal_reason(nil), do: nil
  defp serialize_terminal_reason(:approval_timeout), do: "approval_timeout"

  @spec serialize_output(Output.t() | nil) :: map() | nil
  defp serialize_output(nil), do: nil
  defp serialize_output(%Output{} = output), do: OutputCodec.encode(output)
  @spec serialize_pinned_ids(MapSet.t() | list() | nil) :: [pos_integer()]
  defp serialize_pinned_ids(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort()
  defp serialize_pinned_ids(list) when is_list(list), do: Enum.sort(list)
  defp serialize_pinned_ids(_), do: []

  @spec serialize_usage(MingaAgent.TurnUsage.t()) :: map()
  defp serialize_usage(%MingaAgent.TurnUsage{} = usage) do
    %{
      "input" => usage.input,
      "output" => usage.output,
      "cache_read" => usage.cache_read,
      "cache_write" => usage.cache_write,
      "cost" => usage.cost
    }
  end

  @spec deserialize(map()) :: {:ok, session_data()} | {:error, term()}
  defp deserialize(data) do
    timestamp = string_or_default(data["timestamp"], "")
    transcript = deserialize_transcript(data, timestamp)

    with {:ok, continuation} <- ContinuationCodec.decode(data["continuation"]),
         {:ok, continuation} <-
           Continuation.restore_tool_outcomes(continuation, data["version"], transcript),
         session = data |> deserialize_legacy(transcript) |> Map.put(:continuation, continuation),
         {:ok, session} <- restore_checklist(session, data) do
      restore_checklist_archive(session, data)
    end
  end

  @spec restore_checklist(session_data(), map()) ::
          {:ok, session_data()} | {:error, :invalid_checklist}
  defp restore_checklist(session, %{"checklist" => encoded}) do
    with {:ok, checklist} <- Checklist.decode(encoded),
         do: {:ok, Map.put(session, :checklist, checklist)}
  end

  defp restore_checklist(session, _older_record), do: {:ok, session}

  @spec restore_checklist_archive(session_data(), map()) ::
          {:ok, session_data()} | {:error, :invalid_checklist_archive}
  defp restore_checklist_archive(session, %{"checklist_archive" => encoded}) do
    with {:ok, archive} <- ChecklistArchive.decode(encoded),
         do: {:ok, Map.put(session, :checklist_archive, archive)}
  end

  defp restore_checklist_archive(session, _older_record), do: {:ok, session}

  @spec restore_selection_data(2 | 3 | 4 | 5 | 6, map(), session_data()) ::
          {:ok, session_data()} | {:error, term()}
  defp restore_selection_data(2, data, session) do
    {:ok,
     session
     |> Map.put(:model_selection, nil)
     |> Map.put(:selection_intent, %{
       "model" => data["model_name"],
       "provider" => data["provider_name"]
     })}
  end

  defp restore_selection_data(3, data, session)
       when not is_map_key(data, "model_selection") and not is_map_key(data, "selection_intent"),
       do: restore_selection_data(2, data, session)

  defp restore_selection_data(version, data, session) when version in [3, 4, 5, @version] do
    case data["model_selection"] do
      selection when is_map(selection) ->
        case ModelSelection.decode(selection) do
          {:ok, selection} ->
            {:ok,
             session
             |> Map.put(:model_selection, selection)
             |> Map.put(:selection_intent, data["selection_intent"])}

          {:error, reason} ->
            {:error, {:invalid_saved_model_selection, reason}}
        end

      nil ->
        {:ok,
         session
         |> Map.put(:model_selection, nil)
         |> Map.put(:selection_intent, data["selection_intent"])}
    end
  end

  @spec deserialize_legacy(map()) :: deserialized_transcript_session()
  defp deserialize_legacy(data) do
    timestamp = string_or_default(data["timestamp"], "")
    deserialize_legacy(data, deserialize_transcript(data, timestamp))
  end

  @spec deserialize_legacy(map(), Transcript.t()) :: deserialized_transcript_session()
  defp deserialize_legacy(data, transcript) do
    timestamp = string_or_default(data["timestamp"], "")
    session = deserialize_session(data, timestamp, transcript)

    case Map.fetch(data, "memory") do
      {:ok, memory} when is_binary(memory) -> Map.put(session, :memory, memory)
      {:ok, nil} -> Map.put(session, :memory, nil)
      _missing_or_invalid_memory -> session
    end
  end

  @spec deserialize_transcript(map(), String.t()) :: Transcript.t()
  defp deserialize_transcript(data, timestamp) do
    messages = Enum.map(data["messages"] || [], &deserialize_message/1)
    message_ids = data["message_ids"]
    branches = Enum.map(data["branches"] || [], &deserialize_branch/1)

    Transcript.new([], parse_datetime(timestamp), make_ref())
    |> Transcript.restore(
      messages,
      message_ids,
      branches,
      deserialize_turn_usage(data["usage"] || %{}),
      deserialize_pinned_ids(data["pinned_ids"]),
      parse_datetime(timestamp)
    )
  end

  @spec deserialize_session(map(), String.t(), Transcript.t()) ::
          deserialized_transcript_session()
  defp deserialize_session(data, timestamp, transcript) do
    messages = Transcript.messages(transcript)
    custom_title = stored_custom_title(data)

    %{
      id: string_or_default(data["id"], "unknown"),
      timestamp: timestamp,
      last_message_at: string_or_default(data["last_message_at"], timestamp),
      title: string_or_default(custom_title || data["title"], title_from_messages(messages)),
      custom_title: custom_title,
      archived?: data["archived"] == true,
      model_name: string_or_default(data["model_name"], "unknown"),
      provider_name: string_or_default(data["provider_name"], "unknown"),
      messages: messages,
      message_ids: Enum.map(Transcript.messages_with_ids(transcript), &elem(&1, 0)),
      pinned_ids: Transcript.pinned_ids(transcript),
      usage: Transcript.usage(transcript),
      branches: Transcript.branches(transcript)
    }
  end

  @spec string_or_default(term(), String.t()) :: String.t()
  defp string_or_default(value, _default) when is_binary(value), do: value
  defp string_or_default(_value, default), do: default

  @spec deserialize_pinned_ids(term()) :: MapSet.t()
  defp deserialize_pinned_ids(ids) when is_list(ids), do: MapSet.new(ids)
  defp deserialize_pinned_ids(_), do: MapSet.new()

  @spec deserialize_message(map()) :: MingaAgent.Message.t()
  defp deserialize_message(%{"type" => "user", "text" => text, "attachments" => attachments})
       when is_list(attachments) do
    {:user, text, Enum.map(attachments, &deserialize_attachment/1)}
  end

  defp deserialize_message(%{"type" => "user", "text" => text}), do: {:user, text}
  defp deserialize_message(%{"type" => "assistant", "text" => text}), do: {:assistant, text}

  defp deserialize_message(%{"type" => "thinking", "text" => text, "collapsed" => collapsed}) do
    {:thinking, text, collapsed}
  end

  defp deserialize_message(%{"type" => "tool_call"} = raw) do
    tool_call =
      MingaAgent.ToolCall.restore(
        id: raw["id"],
        name: raw["name"],
        args: raw["args"] || %{},
        status: deserialize_tool_status(raw["status"]),
        terminal_reason: deserialize_terminal_reason(raw["terminal_reason"]),
        result: raw["result"] || "",
        output: deserialize_output(raw["output"]),
        is_error: Map.get(raw, "is_error", false),
        collapsed: Map.get(raw, "collapsed", true),
        auto_approved_scope: deserialize_auto_approved_scope(raw["auto_approved_scope"]),
        preview: deserialize_tool_preview(raw["preview"]),
        started_at: nil,
        duration_ms: raw["duration_ms"]
      )

    {:tool_call, tool_call}
  end

  defp deserialize_message(%{"type" => "system", "text" => text, "level" => level}) do
    {:system, text, deserialize_system_level(level)}
  end

  defp deserialize_message(%{"type" => "usage", "data" => data}) do
    {:usage, deserialize_turn_usage(data)}
  end

  defp deserialize_message(%{"type" => type}) do
    raise ArgumentError, "unsupported persisted message type: #{inspect(type)}"
  end

  @spec deserialize_output(map() | nil) :: Output.t() | nil
  defp deserialize_output(nil), do: nil

  defp deserialize_output(encoded) when is_map(encoded) do
    case OutputCodec.decode(encoded) do
      {:ok, output} -> output
      {:error, reason} -> raise ArgumentError, "invalid persisted output: #{inspect(reason)}"
    end
  end

  @spec deserialize_attachment(map()) :: MingaAgent.Message.image_attachment()
  defp deserialize_attachment(attachment) do
    attachment = Map.new(attachment, fn {key, value} -> {to_string(key), value} end)

    %{
      filename: Map.get(attachment, "filename", "image"),
      size_kb: Map.get(attachment, "size_kb", 0)
    }
  end

  @spec serialize_tool_preview(MingaAgent.ToolApproval.Preview.t() | nil) :: map() | nil
  defp serialize_tool_preview(nil), do: nil

  defp serialize_tool_preview(%MingaAgent.ToolApproval.Preview{} = preview) do
    %{
      "kind" => Atom.to_string(preview.kind),
      "summary" => preview.summary,
      "lines" => preview.lines
    }
  end

  @spec deserialize_tool_preview(map() | nil) :: Preview.t() | nil
  defp deserialize_tool_preview(%{"kind" => kind, "summary" => summary, "lines" => lines})
       when is_binary(summary) and is_list(lines) do
    with {:ok, preview_kind} <- deserialize_preview_kind(kind),
         true <- Enum.all?(lines, &is_binary/1) do
      Preview.new(preview_kind, summary, lines)
    else
      _ -> nil
    end
  end

  defp deserialize_tool_preview(_preview), do: nil

  @spec deserialize_preview_kind(term()) :: {:ok, Preview.kind()} | :error
  defp deserialize_preview_kind("diff"), do: {:ok, :diff}
  defp deserialize_preview_kind(:diff), do: {:ok, :diff}
  defp deserialize_preview_kind("command"), do: {:ok, :command}
  defp deserialize_preview_kind(:command), do: {:ok, :command}
  defp deserialize_preview_kind("target"), do: {:ok, :target}
  defp deserialize_preview_kind(:target), do: {:ok, :target}
  defp deserialize_preview_kind("args"), do: {:ok, :args}
  defp deserialize_preview_kind(:args), do: {:ok, :args}
  defp deserialize_preview_kind(_kind), do: :error

  @spec serialize_auto_approved_scope(MingaAgent.ToolCall.auto_approved_scope() | nil) ::
          String.t() | nil
  defp serialize_auto_approved_scope(nil), do: nil
  defp serialize_auto_approved_scope(scope), do: Atom.to_string(scope)

  @spec deserialize_auto_approved_scope(String.t() | nil) ::
          MingaAgent.ToolCall.auto_approved_scope() | nil
  defp deserialize_auto_approved_scope("session"), do: :session
  defp deserialize_auto_approved_scope("turn"), do: :turn
  defp deserialize_auto_approved_scope(_scope), do: nil

  @spec deserialize_tool_status(String.t() | nil) :: MingaAgent.ToolCall.status()
  defp deserialize_tool_status("running"), do: :running
  defp deserialize_tool_status("complete"), do: :complete
  defp deserialize_tool_status("error"), do: :error
  defp deserialize_tool_status("denied"), do: :denied
  defp deserialize_tool_status("cancelled"), do: :cancelled

  defp deserialize_tool_status(status) do
    raise ArgumentError, "unsupported persisted tool status: #{inspect(status)}"
  end

  defp deserialize_terminal_reason(nil), do: nil
  defp deserialize_terminal_reason("approval_timeout"), do: :approval_timeout

  @spec deserialize_system_level(String.t() | nil) :: MingaAgent.Message.system_level()
  defp deserialize_system_level("error"), do: :error
  defp deserialize_system_level(_level), do: :info

  @spec serialize_branch(MingaAgent.Branch.t()) :: map()
  defp serialize_branch(%MingaAgent.Branch{} = branch) do
    %{
      "name" => branch.name,
      "messages" => branch |> MingaAgent.Branch.messages() |> Enum.map(&serialize_message/1),
      "message_ids" => MingaAgent.Branch.entry_ids(branch),
      "created_at" => DateTime.to_iso8601(branch.created_at)
    }
  end

  @spec deserialize_branch(map()) :: Transcript.restore_branch()
  defp deserialize_branch(data) do
    messages = Enum.map(data["messages"] || [], &deserialize_message/1)
    ids = if is_list(data["message_ids"]), do: data["message_ids"], else: []

    {data["name"] || "branch", messages, ids, parse_datetime(data["created_at"])}
  end

  @spec deserialize_turn_usage(map()) :: MingaAgent.TurnUsage.t()
  defp deserialize_turn_usage(data) do
    %MingaAgent.TurnUsage{
      input: data["input"] || 0,
      output: data["output"] || 0,
      cache_read: data["cache_read"] || 0,
      cache_write: data["cache_write"] || 0,
      cost: data["cost"] || 0.0
    }
  end

  @spec parse_datetime(String.t() | nil) :: DateTime.t()
  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  # ── Private: metadata extraction ───────────────────────────────────────────

  @spec recovery_entry(map(), String.t()) :: recovery_entry() | nil
  defp recovery_entry(record, path) do
    case conversation_meta(record_conversation(record)) do
      nil -> draft_recovery_entry(record, path)
      meta -> {:conversation, meta}
    end
  end

  @spec draft_recovery_entry(map(), String.t()) :: recovery_entry() | nil
  defp draft_recovery_entry(
         %{"version" => @envelope_version, "id" => id, "conversation" => nil} = record,
         path
       )
       when is_binary(id) do
    with :ok <- validate_presentation_id(id),
         ^id <- Path.basename(path, ".json"),
         {:ok, {_revision, %DraftSnapshot{}}} <- decode_presentation(record),
         {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, time} <- DateTime.from_unix(mtime) do
      {:draft_only, id, DateTime.to_iso8601(time)}
    else
      _ -> nil
    end
  end

  defp draft_recovery_entry(_record, _path), do: nil

  @spec recovery_timestamp(recovery_entry()) :: String.t()
  defp recovery_timestamp({:conversation, meta}), do: meta.last_message_at
  defp recovery_timestamp({:draft_only, _id, timestamp}), do: timestamp

  @spec conversation_meta(term()) :: session_meta() | nil
  defp conversation_meta(%{"id" => id} = data) when is_binary(id) do
    if data["version"] in [nil, 1, 2, 3, 4, 5, @version] do
      messages = data["messages"] || []
      preview = first_user_preview(messages)
      timestamp = data["timestamp"] || ""
      last_message_at = data["last_message_at"] || timestamp

      %{
        id: id,
        timestamp: timestamp,
        last_message_at: last_message_at,
        title: stored_custom_title(data) || data["title"] || preview,
        archived?: data["archived"] == true,
        model_name: data["model_name"] || "unknown",
        provider_name: data["provider_name"] || "unknown",
        preview: preview,
        recent_messages: recent_messages(messages),
        message_count: Enum.count(messages),
        turn_count: count_user_messages(messages),
        cost: total_cost(data, messages),
        continuation_kind: continuation_kind(data)
      }
    end
  end

  defp conversation_meta(_conversation), do: nil

  @spec record_conversation(map()) :: map() | nil
  defp record_conversation(%{"version" => @envelope_version} = record), do: record["conversation"]
  defp record_conversation(record), do: record

  @spec continuation_kind(map()) ::
          :lossless | :legacy_reconstructed | :legacy_import_required
  defp continuation_kind(%{
         "version" => version,
         "continuation" => %{"provenance" => "legacy_reconstructed"}
       })
       when version in [2, 3, 4, 5, @version],
       do: :legacy_reconstructed

  defp continuation_kind(%{"version" => version})
       when version in [2, 3, 4, 5, @version],
       do: :lossless

  defp continuation_kind(_data), do: :legacy_import_required

  @spec title_from_messages([MingaAgent.Message.t()]) :: String.t()
  defp title_from_messages(messages) do
    messages
    |> Enum.find_value(fn
      {:user, text} when is_binary(text) -> text
      {:user, text, _attachments} when is_binary(text) -> text
      _ -> nil
    end)
    |> readable_title()
  end

  @spec first_user_preview([map()]) :: String.t()
  defp first_user_preview(messages) do
    messages
    |> Enum.find_value(fn
      %{"type" => "user", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
    |> readable_title()
  end

  @spec readable_title(String.t() | nil) :: String.t()
  defp readable_title(nil), do: "(empty)"

  defp readable_title(text) do
    text
    |> String.split("\n")
    |> hd()
    |> String.trim()
    |> truncate(80)
    |> case do
      "" -> "(empty)"
      title -> title
    end
  end

  @spec recent_messages([map()]) :: String.t()
  defp recent_messages(messages) do
    messages
    |> Enum.reverse()
    |> Enum.filter(fn m -> m["type"] in ["user", "assistant"] end)
    |> Enum.take(6)
    |> Enum.reverse()
    |> Enum.map_join(" ", fn m -> m["text"] || "" end)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(240)
  end

  @spec count_user_messages([map()]) :: non_neg_integer()
  defp count_user_messages(messages) do
    Enum.count(messages, fn m -> m["type"] == "user" end)
  end

  @spec total_cost(map(), [map()]) :: float()
  defp total_cost(data, messages) do
    case data["usage"] do
      %{"cost" => cost} when is_number(cost) -> cost
      _ -> Enum.reduce(messages, 0.0, fn m, acc -> acc + (get_in(m, ["data", "cost"]) || 0.0) end)
    end
  end

  @spec truncate(String.t(), pos_integer()) :: String.t()
  defp truncate(text, max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length - 3) <> "..."
    else
      text
    end
  end

  @spec decode_json(String.t()) :: {:ok, term()} | {:error, term()}
  defp decode_json(json) do
    {:ok, JSON.decode!(json)}
  rescue
    e -> {:error, e}
  end
end

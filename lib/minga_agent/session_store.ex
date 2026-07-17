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

  alias MingaAgent.ToolApproval.Preview

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
          cost: float()
        }

  @typedoc "Full session data for save/load."
  @type session_data :: %{
          required(:id) => String.t(),
          required(:timestamp) => String.t(),
          required(:model_name) => String.t(),
          required(:messages) => [MingaAgent.Message.t()],
          required(:usage) => MingaAgent.TurnUsage.t(),
          optional(:last_message_at) => String.t(),
          optional(:title) => String.t(),
          optional(:provider_name) => String.t(),
          optional(:branches) => [MingaAgent.Branch.t()],
          optional(:message_ids) => [pos_integer()],
          optional(:pinned_ids) => MapSet.t(pos_integer()),
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

  Creates the sessions directory if it doesn't exist. Writes atomically
  via a temp file to avoid corruption.
  """
  @spec save(session_data(), String.t() | nil) :: :ok | {:error, term()}
  def save(%{id: id} = data, config_dir \\ nil) when is_binary(id) do
    path = Path.join(sessions_dir(config_dir), "#{id}.json")
    json = JSON.encode!(serialize(data))

    case atomic_write_private(path, json) do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(:agent, "[SessionStore] failed to save #{id}: #{reason}")
        {:error, reason}
    end
  end

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
      case data["remote_token"] do
        token when is_binary(token) -> {:ok, token}
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
  Loads a persisted session transcript.

  Returns `{:ok, session_data}` or `{:error, reason}`.
  """
  @spec load(String.t(), String.t() | nil) :: {:ok, session_data()} | {:error, term()}
  def load(session_id, config_dir \\ nil) when is_binary(session_id) do
    path = Path.join(sessions_dir(config_dir), "#{session_id}.json")

    with {:ok, json} <- File.read(path),
         {:ok, data} when is_map(data) <- decode_json(json) do
      {:ok, deserialize(data)}
    else
      {:ok, _other} -> {:error, :invalid_session_record}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all saved sessions as metadata (without full messages).

  Returns sessions sorted by last message timestamp, most recent first.
  """
  @spec list(String.t() | nil) :: [session_meta()]
  def list(config_dir \\ nil) do
    dir = sessions_dir(config_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reject(&String.ends_with?(&1, ".tmp"))
        |> Enum.map(fn file -> load_meta(Path.join(dir, file)) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.last_message_at, :desc)

      {:error, _} ->
        []
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
    with :ok <- File.write(path, contents),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(path)
        error
    end
  end

  @spec atomic_write_private(String.t(), String.t()) :: :ok | {:error, term()}
  defp atomic_write_private(path, contents) do
    tmp_path = path <> ".tmp"

    with :ok <- ensure_private_dir(Path.dirname(path)),
         :ok <- write_private_file(tmp_path, contents),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp_path)
        error
    end
  end

  @doc "Deletes a saved session transcript. Durable remote identity is retained."
  @spec delete(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def delete(session_id, config_dir \\ nil) when is_binary(session_id) do
    path = Path.join(sessions_dir(config_dir), "#{session_id}.json")
    File.rm(path)
  end

  @doc "Deletes all saved session transcripts. Durable remote identities are retained."
  @spec clear_all(String.t() | nil) :: :ok
  def clear_all(config_dir \\ nil) do
    dir = sessions_dir(config_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.each(fn file -> File.rm(Path.join(dir, file)) end)

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Prunes session transcripts older than `days` days.

  Returns the number of transcripts deleted. Durable remote identities are retained.
  """
  @spec prune(non_neg_integer(), String.t() | nil) :: non_neg_integer()
  def prune(days, config_dir \\ nil) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    cutoff_str = DateTime.to_iso8601(cutoff)

    pruned =
      list(config_dir)
      |> Enum.filter(fn meta -> meta.timestamp < cutoff_str end)

    Enum.each(pruned, fn meta -> delete(meta.id, config_dir) end)
    Enum.count(pruned)
  end

  # ── Private: serialization ─────────────────────────────────────────────────

  @spec serialize(session_data()) :: map()
  defp serialize(data) do
    messages = Map.get(data, :messages, [])
    timestamp = Map.get(data, :timestamp) || DateTime.to_iso8601(DateTime.utc_now())

    %{
      "id" => data.id,
      "timestamp" => timestamp,
      "last_message_at" => Map.get(data, :last_message_at, timestamp),
      "title" => Map.get(data, :title) || title_from_messages(messages),
      "model_name" => data.model_name,
      "provider_name" => Map.get(data, :provider_name, "unknown"),
      "messages" => Enum.map(messages, &serialize_message/1),
      "message_ids" => Map.get(data, :message_ids, []),
      "pinned_ids" => serialize_pinned_ids(Map.get(data, :pinned_ids)),
      "usage" => serialize_usage(data.usage),
      "branches" => Enum.map(Map.get(data, :branches, []), &serialize_branch/1),
      "memory" => Map.get(data, :memory)
    }
  end

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
      "result" => tc.result,
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

  @spec deserialize(map()) :: session_data()
  defp deserialize(data) do
    messages = Enum.map(data["messages"] || [], &deserialize_message/1)
    timestamp = data["timestamp"] || ""

    session = %{
      id: data["id"],
      timestamp: timestamp,
      last_message_at: data["last_message_at"] || timestamp,
      title: data["title"] || title_from_messages(messages),
      model_name: data["model_name"] || "unknown",
      provider_name: data["provider_name"] || "unknown",
      messages: messages,
      message_ids: deserialize_message_ids(data["message_ids"], Enum.count(messages)),
      pinned_ids: deserialize_pinned_ids(data["pinned_ids"]),
      usage: deserialize_turn_usage(data["usage"] || %{}),
      branches: Enum.map(data["branches"] || [], &deserialize_branch/1)
    }

    if Map.has_key?(data, "memory"), do: Map.put(session, :memory, data["memory"]), else: session
  end

  @spec deserialize_message_ids(term(), non_neg_integer()) :: [pos_integer()]
  defp deserialize_message_ids(ids, _msg_count) when is_list(ids) and ids != [], do: ids
  defp deserialize_message_ids(_, msg_count), do: Enum.to_list(1..max(msg_count, 1))

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
    {:tool_call,
     %MingaAgent.ToolCall{
       id: raw["id"],
       name: raw["name"],
       args: raw["args"] || %{},
       status: deserialize_tool_status(raw["status"]),
       result: raw["result"] || "",
       is_error: raw["is_error"] || false,
       collapsed: raw["collapsed"] || true,
       auto_approved_scope: deserialize_auto_approved_scope(raw["auto_approved_scope"]),
       preview: deserialize_tool_preview(raw["preview"]),
       started_at: nil,
       duration_ms: raw["duration_ms"]
     }}
  end

  defp deserialize_message(%{"type" => "system", "text" => text, "level" => level}) do
    {:system, text, deserialize_system_level(level)}
  end

  defp deserialize_message(%{"type" => "usage", "data" => data}) do
    {:usage, deserialize_turn_usage(data)}
  end

  # Fallback for unknown message types
  defp deserialize_message(%{"type" => type} = msg) do
    {:system, "Unknown message type: #{type} - #{inspect(msg)}", :info}
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
  defp deserialize_tool_status(_status), do: :complete

  @spec deserialize_system_level(String.t() | nil) :: MingaAgent.Message.system_level()
  defp deserialize_system_level("error"), do: :error
  defp deserialize_system_level(_level), do: :info

  @spec serialize_branch(MingaAgent.Branch.t()) :: map()
  defp serialize_branch(%MingaAgent.Branch{} = branch) do
    %{
      "name" => branch.name,
      "messages" => Enum.map(branch.messages, &serialize_message/1),
      "created_at" => DateTime.to_iso8601(branch.created_at)
    }
  end

  @spec deserialize_branch(map()) :: MingaAgent.Branch.t()
  defp deserialize_branch(data) do
    %MingaAgent.Branch{
      name: data["name"] || "branch",
      messages: Enum.map(data["messages"] || [], &deserialize_message/1),
      created_at: parse_datetime(data["created_at"])
    }
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

  @spec load_meta(String.t()) :: session_meta() | nil
  defp load_meta(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} when is_map(data) <- decode_json(json) do
      messages = data["messages"] || []
      preview = first_user_preview(messages)
      timestamp = data["timestamp"] || ""
      last_message_at = data["last_message_at"] || timestamp

      %{
        id: data["id"],
        timestamp: timestamp,
        last_message_at: last_message_at,
        title: data["title"] || preview,
        model_name: data["model_name"] || "unknown",
        provider_name: data["provider_name"] || "unknown",
        preview: preview,
        recent_messages: recent_messages(messages),
        message_count: Enum.count(messages),
        turn_count: count_user_messages(messages),
        cost: total_cost(data, messages)
      }
    else
      _ -> nil
    end
  end

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

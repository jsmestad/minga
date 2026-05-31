defmodule MingaAgent.SessionStore do
  @moduledoc """
  Persists agent conversations to disk as JSON files.

  Each session is saved as `{session_id}.json` in the sessions directory
  (`~/.config/minga/agent/sessions/` by default). Files are written
  atomically via a temp file + rename to avoid corruption on crash.

  The store is stateless: all functions operate directly on the filesystem.
  The `Session` GenServer calls `save/2` on a debounced timer, and the
  picker calls `list/0` to scan the directory for past sessions.
  """

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
          optional(:remote_token) => String.t() | nil,
          optional(:provider_name) => String.t(),
          optional(:branches) => [MingaAgent.Branch.t()],
          optional(:message_ids) => [pos_integer()],
          optional(:pinned_ids) => MapSet.t(pos_integer()),
          optional(:memory) => String.t() | nil
        }

  @doc "Returns the sessions directory path."
  @spec sessions_dir(String.t() | nil) :: String.t()
  def sessions_dir(config_dir \\ nil) do
    config_dir =
      config_dir || System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")

    Path.join([config_dir, "minga", "agent", "sessions"])
  end

  @doc """
  Saves a session to disk.

  Creates the sessions directory if it doesn't exist. Writes atomically
  via a temp file to avoid corruption.
  """
  @spec save(session_data(), String.t() | nil) :: :ok | {:error, term()}
  def save(%{id: id} = data, config_dir \\ nil) when is_binary(id) do
    dir = sessions_dir(config_dir)
    path = Path.join(dir, "#{id}.json")
    tmp_path = path <> ".tmp"
    json = JSON.encode!(serialize(data))

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, json),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        Minga.Log.warning(:agent, "[SessionStore] failed to save #{id}: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Loads a session from disk.

  Returns `{:ok, session_data}` or `{:error, reason}`.
  """
  @spec load(String.t(), String.t() | nil) :: {:ok, session_data()} | {:error, term()}
  def load(session_id, config_dir \\ nil) when is_binary(session_id) do
    path = Path.join(sessions_dir(config_dir), "#{session_id}.json")

    with {:ok, json} <- File.read(path),
         {:ok, data} <- decode_json(json) do
      {:ok, deserialize(data)}
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

  @doc "Deletes a saved session."
  @spec delete(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def delete(session_id, config_dir \\ nil) when is_binary(session_id) do
    path = Path.join(sessions_dir(config_dir), "#{session_id}.json")
    File.rm(path)
  end

  @doc "Deletes all saved sessions."
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
  Prunes sessions older than `days` days.

  Returns the number of sessions deleted.
  """
  @spec prune(non_neg_integer(), String.t() | nil) :: non_neg_integer()
  def prune(days, config_dir \\ nil) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    cutoff_str = DateTime.to_iso8601(cutoff)

    pruned =
      list(config_dir)
      |> Enum.filter(fn meta -> meta.timestamp < cutoff_str end)

    Enum.each(pruned, fn meta -> delete(meta.id, config_dir) end)
    length(pruned)
  end

  # ── Private: serialization ─────────────────────────────────────────────────

  @spec serialize(session_data()) :: map()
  defp serialize(data) do
    messages = Map.get(data, :messages, [])
    timestamp = Map.get(data, :timestamp) || DateTime.to_iso8601(DateTime.utc_now())

    %{
      "id" => data.id,
      "remote_token" => Map.get(data, :remote_token),
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
      "duration_ms" => tc.duration_ms
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
      remote_token: data["remote_token"],
      timestamp: timestamp,
      last_message_at: data["last_message_at"] || timestamp,
      title: data["title"] || title_from_messages(messages),
      model_name: data["model_name"] || "unknown",
      provider_name: data["provider_name"] || "unknown",
      messages: messages,
      message_ids: deserialize_message_ids(data["message_ids"], length(messages)),
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
    %{
      filename: attachment["filename"] || attachment[:filename] || "image",
      size_kb: attachment["size_kb"] || attachment[:size_kb] || 0
    }
  end

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
         {:ok, data} <- decode_json(json) do
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
        message_count: length(messages),
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

  @spec decode_json(String.t()) :: {:ok, map()} | {:error, term()}
  defp decode_json(json) do
    {:ok, JSON.decode!(json)}
  rescue
    e -> {:error, e}
  end
end

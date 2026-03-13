defmodule Minga.Agent.SessionStore do
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
          model_name: String.t(),
          preview: String.t(),
          message_count: non_neg_integer(),
          cost: float()
        }

  @typedoc "Full session data for save/load."
  @type session_data :: %{
          id: String.t(),
          timestamp: String.t(),
          model_name: String.t(),
          messages: [map()],
          usage: map()
        }

  @doc "Returns the sessions directory path."
  @spec sessions_dir() :: String.t()
  def sessions_dir do
    config_dir = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([config_dir, "minga", "agent", "sessions"])
  end

  @doc """
  Saves a session to disk.

  Creates the sessions directory if it doesn't exist. Writes atomically
  via a temp file to avoid corruption.
  """
  @spec save(session_data()) :: :ok | {:error, term()}
  def save(%{id: id} = data) when is_binary(id) do
    dir = sessions_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{id}.json")
    tmp_path = path <> ".tmp"

    json = JSON.encode!(serialize(data))

    case File.write(tmp_path, json) do
      :ok ->
        File.rename(tmp_path, path)

      {:error, reason} ->
        Minga.Log.warning(:agent, "[SessionStore] failed to save #{id}: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Loads a session from disk.

  Returns `{:ok, session_data}` or `{:error, reason}`.
  """
  @spec load(String.t()) :: {:ok, session_data()} | {:error, term()}
  def load(session_id) when is_binary(session_id) do
    path = Path.join(sessions_dir(), "#{session_id}.json")

    with {:ok, json} <- File.read(path),
         {:ok, data} <- decode_json(json) do
      {:ok, deserialize(data)}
    end
  end

  @doc """
  Lists all saved sessions as metadata (without full messages).

  Returns sessions sorted by timestamp, most recent first.
  """
  @spec list() :: [session_meta()]
  def list do
    dir = sessions_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reject(&String.ends_with?(&1, ".tmp"))
        |> Enum.map(fn file -> load_meta(Path.join(dir, file)) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.timestamp, :desc)

      {:error, _} ->
        []
    end
  end

  @doc "Deletes a saved session."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(session_id) when is_binary(session_id) do
    path = Path.join(sessions_dir(), "#{session_id}.json")
    File.rm(path)
  end

  @doc "Deletes all saved sessions."
  @spec clear_all() :: :ok
  def clear_all do
    dir = sessions_dir()

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
  @spec prune(non_neg_integer()) :: non_neg_integer()
  def prune(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    cutoff_str = DateTime.to_iso8601(cutoff)

    pruned =
      list()
      |> Enum.filter(fn meta -> meta.timestamp < cutoff_str end)

    Enum.each(pruned, fn meta -> delete(meta.id) end)
    length(pruned)
  end

  # ── Private: serialization ─────────────────────────────────────────────────

  @spec serialize(session_data()) :: map()
  defp serialize(data) do
    %{
      "id" => data.id,
      "timestamp" => data.timestamp,
      "model_name" => data.model_name,
      "messages" => Enum.map(data.messages, &serialize_message/1),
      "usage" => serialize_usage(data.usage)
    }
  end

  @spec serialize_message(Minga.Agent.Message.t()) :: map()
  defp serialize_message({:user, text, _attachments}), do: %{"type" => "user", "text" => text}
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
      "duration_ms" => tc.duration_ms
    }
  end

  defp serialize_message({:system, text, level}) do
    %{"type" => "system", "text" => text, "level" => Atom.to_string(level)}
  end

  defp serialize_message({:usage, usage}),
    do: %{"type" => "usage", "data" => serialize_usage(usage)}

  @spec serialize_usage(map()) :: map()
  defp serialize_usage(usage) do
    %{
      "input" => Map.get(usage, :input, 0),
      "output" => Map.get(usage, :output, 0),
      "cache_read" => Map.get(usage, :cache_read, 0),
      "cache_write" => Map.get(usage, :cache_write, 0),
      "cost" => Map.get(usage, :cost, 0.0)
    }
  end

  @spec deserialize(map()) :: session_data()
  defp deserialize(data) do
    %{
      id: data["id"],
      timestamp: data["timestamp"],
      model_name: data["model_name"] || "unknown",
      messages: Enum.map(data["messages"] || [], &deserialize_message/1),
      usage: deserialize_usage(data["usage"] || %{})
    }
  end

  @spec deserialize_message(map()) :: Minga.Agent.Message.t()
  defp deserialize_message(%{"type" => "user", "text" => text}), do: {:user, text}
  defp deserialize_message(%{"type" => "assistant", "text" => text}), do: {:assistant, text}

  defp deserialize_message(%{"type" => "thinking", "text" => text, "collapsed" => collapsed}) do
    {:thinking, text, collapsed}
  end

  defp deserialize_message(%{"type" => "tool_call"} = tc) do
    {:tool_call,
     %{
       id: tc["id"],
       name: tc["name"],
       args: tc["args"] || %{},
       status: String.to_existing_atom(tc["status"] || "complete"),
       result: tc["result"] || "",
       is_error: tc["is_error"] || false,
       collapsed: tc["collapsed"] || true,
       started_at: nil,
       duration_ms: tc["duration_ms"]
     }}
  end

  defp deserialize_message(%{"type" => "system", "text" => text, "level" => level}) do
    {:system, text, String.to_existing_atom(level)}
  end

  defp deserialize_message(%{"type" => "usage", "data" => data}) do
    {:usage, deserialize_usage(data)}
  end

  # Fallback for unknown message types
  defp deserialize_message(%{"type" => type} = msg) do
    {:system, "Unknown message type: #{type} - #{inspect(msg)}", :info}
  end

  @spec deserialize_usage(map()) :: map()
  defp deserialize_usage(data) do
    %{
      input: data["input"] || 0,
      output: data["output"] || 0,
      cache_read: data["cache_read"] || 0,
      cache_write: data["cache_write"] || 0,
      cost: data["cost"] || 0.0
    }
  end

  # ── Private: metadata extraction ───────────────────────────────────────────

  @spec load_meta(String.t()) :: session_meta() | nil
  defp load_meta(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- decode_json(json) do
      messages = data["messages"] || []
      first_user = Enum.find(messages, fn m -> m["type"] == "user" end)

      preview =
        case first_user do
          %{"text" => text} -> String.slice(text, 0, 80)
          nil -> "(empty)"
        end

      total_cost =
        messages
        |> Enum.filter(fn m -> m["type"] == "usage" end)
        |> Enum.reduce(0.0, fn m, acc -> acc + (get_in(m, ["data", "cost"]) || 0.0) end)

      %{
        id: data["id"],
        timestamp: data["timestamp"] || "",
        model_name: data["model_name"] || "unknown",
        preview: preview,
        message_count: length(messages),
        cost: total_cost
      }
    else
      _ -> nil
    end
  end

  @spec decode_json(String.t()) :: {:ok, map()} | {:error, term()}
  defp decode_json(json) do
    {:ok, JSON.decode!(json)}
  rescue
    e -> {:error, e}
  end
end

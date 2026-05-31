defmodule Minga.Remote.ControlEndpoint do
  @moduledoc false

  @default_dir "minga-control"
  @default_file "control.node"

  @doc "Returns the local control endpoint path used by detached CLI commands."
  @spec path() :: String.t()
  def path do
    Application.get_env(:minga, :local_control_endpoint_path, default_path())
  end

  @doc "Publishes the current distributed node as the local control endpoint."
  @spec publish_current_node() :: :ok | {:error, term()}
  def publish_current_node do
    if Node.alive?() do
      write_node(Node.self())
    else
      clear_current_node()
    end
  end

  @doc "Reads the published local control endpoint node, if any."
  @spec read_node() :: {:ok, node()} | {:error, :not_found | term()}
  def read_node do
    with :ok <- validate_regular_user_file(path()),
         {:ok, contents} <- File.read(path()) do
      parse_node(String.trim(contents))
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes the endpoint only when this VM published it."
  @spec clear_current_node() :: :ok
  def clear_current_node do
    case read_node() do
      {:ok, node} -> clear_matching_node(node, Node.self())
      _other -> :ok
    end
  end

  @spec clear_matching_node(node(), node()) :: :ok
  defp clear_matching_node(node, node), do: clear()
  defp clear_matching_node(_node, _current), do: :ok

  @doc "Deletes the published local control endpoint, if present."
  @spec clear() :: :ok
  def clear do
    case File.rm(path()) do
      {:error, :enoent} -> :ok
      _ -> :ok
    end
  end

  @spec write_node(node()) :: :ok | {:error, term()}
  defp write_node(node_name) when is_atom(node_name) do
    file = path()

    case ensure_endpoint_dir(Path.dirname(file)) do
      :ok -> write_endpoint_file(file, Atom.to_string(node_name) <> "\n")
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_endpoint_dir(String.t()) :: :ok | {:error, term()}
  defp ensure_endpoint_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> File.chmod(dir, 0o700)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_endpoint_file(String.t(), String.t()) :: :ok | {:error, term()}
  defp write_endpoint_file(file, contents) do
    tmp = "#{file}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(tmp, contents),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp)
        error
    end
  end

  @spec validate_regular_user_file(String.t()) :: :ok | {:error, term()}
  defp validate_regular_user_file(file) do
    case File.lstat(file) do
      {:ok, %{type: :regular, uid: uid}} -> validate_file_owner(uid, current_uid())
      {:ok, %{type: type}} -> {:error, {:invalid_endpoint_file_type, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_file_owner(non_neg_integer(), non_neg_integer() | nil) :: :ok | {:error, term()}
  defp validate_file_owner(_uid, nil), do: :ok
  defp validate_file_owner(uid, uid), do: :ok
  defp validate_file_owner(uid, expected), do: {:error, {:invalid_endpoint_owner, uid, expected}}

  @spec current_uid() :: non_neg_integer() | nil
  defp current_uid do
    case System.get_env("UID") do
      nil -> nil
      uid -> String.to_integer(uid)
    end
  rescue
    _error -> nil
  end

  @spec parse_node(String.t()) :: {:ok, node()} | {:error, :invalid_node_name}
  defp parse_node(""), do: {:error, :invalid_node_name}

  defp parse_node(node_name) when is_binary(node_name) do
    if valid_node_name?(node_name) do
      {:ok, :erlang.binary_to_atom(node_name, :utf8)}
    else
      {:error, :invalid_node_name}
    end
  end

  @spec valid_node_name?(String.t()) :: boolean()
  defp valid_node_name?(node_name) when is_binary(node_name) do
    byte_size(node_name) <= 255 and Regex.match?(~r/^[A-Za-z0-9_.@-]+$/, node_name)
  end

  @spec default_path() :: String.t()
  defp default_path do
    base_dir =
      System.get_env("XDG_RUNTIME_DIR") ||
        Path.join(System.tmp_dir!(), "#{@default_dir}-#{endpoint_owner_suffix()}")

    Path.join(base_dir, @default_file)
  end

  @spec endpoint_owner_suffix() :: String.t()
  defp endpoint_owner_suffix do
    System.get_env("UID") || System.get_env("USER") || "unknown"
  end
end

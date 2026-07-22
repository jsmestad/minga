defmodule MingaEditor.NativeIPC.Endpoint do
  @moduledoc false

  import Bitwise

  alias MingaEditor.NativeIPC.Identity

  @max_frame 65_536
  @descriptor_version 1

  @enforce_keys [:listener, :identity, :descriptor_path]
  defstruct [:listener, :identity, :descriptor_path]

  @type t :: %__MODULE__{
          listener: port(),
          identity: Identity.t(),
          descriptor_path: String.t()
        }

  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) do
    runtime_dir = Keyword.fetch!(opts, :runtime_dir)
    base = Keyword.fetch!(opts, :identity_base)
    socket_path = random_socket_path(runtime_dir)

    with {:ok, listener} <- listen(socket_path) do
      endpoint = %__MODULE__{
        listener: listener,
        identity: build_identity(base, socket_path),
        descriptor_path: Path.join(runtime_dir, "current.json")
      }

      with :ok <- File.chmod(socket_path, 0o600),
           :ok <- validate_private_file(socket_path, :other, base.euid, 0o600),
           :ok <- publish_descriptor(endpoint.descriptor_path, endpoint.identity, base.euid) do
        {:ok, endpoint}
      else
        {:error, _reason} = error ->
          close(endpoint)
          error
      end
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{} = endpoint) do
    remove_descriptor_if_current(endpoint.descriptor_path, endpoint.identity.core_instance_id)
    _ = :gen_tcp.close(endpoint.listener)
    _ = File.rm(endpoint.identity.socket_path)
    :ok
  end

  @spec build_identity(map(), String.t()) :: Identity.t()
  defp build_identity(base, socket_path) do
    Identity.new(
      app_instance_id: base.app_instance_id,
      core_instance_id: base.core_instance_id,
      app_pid: base.app_pid,
      euid: base.euid,
      launch_nonce: base.launch_nonce,
      socket_path: socket_path,
      token: base.token
    )
  end

  @spec listen(String.t()) :: {:ok, port()} | {:error, term()}
  defp listen(socket_path) do
    :gen_tcp.listen(0, [
      :binary,
      {:ifaddr, {:local, socket_path}},
      {:active, false},
      {:packet, 4},
      {:packet_size, @max_frame},
      {:reuseaddr, true}
    ])
  end

  @spec publish_descriptor(String.t(), Identity.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp publish_descriptor(path, identity, euid) do
    temp = path <> ".tmp-#{random_secret(8)}"

    with :ok <-
           File.write(
             temp,
             JSON.encode!(Identity.descriptor(identity, @descriptor_version)) <> "\n",
             [:exclusive]
           ),
         :ok <- File.chmod(temp, 0o600),
         :ok <- validate_private_file(temp, :regular, euid, 0o600) do
      publish_current_descriptor(path, temp, identity, euid)
    else
      {:error, _reason} = error -> remove_temp_descriptor(temp, error)
    end
  end

  @spec publish_current_descriptor(String.t(), String.t(), Identity.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp publish_current_descriptor(path, temp, identity, euid) do
    case File.rename(temp, path) do
      :ok -> validate_published_descriptor(path, identity, euid)
      {:error, _reason} = error -> remove_temp_descriptor(temp, error)
    end
  end

  @spec validate_published_descriptor(String.t(), Identity.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp validate_published_descriptor(path, identity, euid) do
    case validate_private_file(path, :regular, euid, 0o600) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        remove_descriptor_if_current(path, identity.core_instance_id)
        error
    end
  end

  @spec remove_temp_descriptor(String.t(), {:error, term()}) :: {:error, term()}
  defp remove_temp_descriptor(temp, error) do
    _ = File.rm(temp)
    error
  end

  @spec remove_descriptor_if_current(String.t(), String.t()) :: :ok
  defp remove_descriptor_if_current(path, core_instance_id) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"core_instance_id" => ^core_instance_id}} <- JSON.decode(contents) do
      _ = File.rm(path)
    end

    :ok
  end

  @spec validate_private_file(String.t(), atom(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp validate_private_file(path, expected_type, euid, permissions) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^expected_type, uid: ^euid, mode: mode}}
      when (mode &&& 0o777) == permissions ->
        :ok

      {:ok, %File.Stat{} = stat} ->
        {:error, {:insecure_runtime_entry, path, stat.type, stat.uid, stat.mode &&& 0o777}}

      {:error, reason} ->
        {:error, {:runtime_entry, path, reason}}
    end
  end

  @spec random_socket_path(String.t()) :: String.t()
  defp random_socket_path(runtime_dir),
    do: Path.join(runtime_dir, "control-#{random_secret(12)}.sock")

  @spec random_secret(pos_integer()) :: String.t()
  defp random_secret(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end

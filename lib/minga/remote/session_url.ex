defmodule Minga.Remote.SessionURL do
  @moduledoc "Parses remote agent session URLs accepted by CLI subcommands."

  @enforce_keys [:scheme, :host, :path]
  defstruct [:scheme, :user, :host, :port, :path]

  @type t :: %__MODULE__{
          scheme: :ssh,
          user: String.t() | nil,
          host: String.t(),
          port: pos_integer() | nil,
          path: String.t() | nil
        }

  @doc "Parses `ssh://[user@]host[:port][/path]`."
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, :invalid_url | :missing_path}
  def parse(url, opts \\ []) when is_binary(url) do
    require_path? = Keyword.get(opts, :require_path?, true)
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri),
         :ok <- validate_host(uri),
         {:ok, path} <- validate_path(uri.path, require_path?) do
      {:ok,
       %__MODULE__{
         scheme: :ssh,
         user: uri.userinfo,
         host: uri.host,
         port: uri.port,
         path: path
       }}
    end
  end

  @doc "Returns the SSH target string for display."
  @spec ssh_target(t()) :: String.t()
  def ssh_target(%__MODULE__{user: nil, host: host}), do: host
  def ssh_target(%__MODULE__{user: user, host: host}), do: "#{user}@#{host}"

  @doc "Returns a stable display/server name for this URL."
  @spec server_name(t()) :: String.t()
  def server_name(%__MODULE__{user: nil, host: host}), do: host
  def server_name(%__MODULE__{user: user, host: host}), do: "#{user}@#{host}"

  defp validate_scheme(%URI{scheme: "ssh"}), do: :ok
  defp validate_scheme(_uri), do: {:error, :invalid_url}

  defp validate_host(%URI{host: host, userinfo: user}) when is_binary(host) and host != "" do
    case validate_ssh_component(host, 253) do
      :ok -> validate_optional_user(user)
      error -> error
    end
  end

  defp validate_host(_uri), do: {:error, :invalid_url}

  @spec validate_optional_user(String.t() | nil) :: :ok | {:error, :invalid_url}
  defp validate_optional_user(nil), do: :ok
  defp validate_optional_user(user), do: validate_ssh_component(user, 128)

  @spec validate_ssh_component(String.t(), pos_integer()) :: :ok | {:error, :invalid_url}
  defp validate_ssh_component("", _max_length), do: {:error, :invalid_url}

  defp validate_ssh_component("-" <> _rest, _max_length), do: {:error, :invalid_url}

  defp validate_ssh_component(value, max_length) when byte_size(value) > max_length do
    {:error, :invalid_url}
  end

  defp validate_ssh_component(value, _max_length) do
    validate_ssh_component_chars(value, Regex.match?(~r/[\x00-\x20\x7F]/, value))
  end

  @spec validate_ssh_component_chars(String.t(), boolean()) :: :ok | {:error, :invalid_url}
  defp validate_ssh_component_chars(_value, true), do: {:error, :invalid_url}
  defp validate_ssh_component_chars(_value, false), do: :ok

  defp validate_path(nil, false), do: {:ok, nil}
  defp validate_path("", false), do: {:ok, nil}
  defp validate_path(path, _require_path?) when is_binary(path) and path != "/", do: {:ok, path}
  defp validate_path(_path, true), do: {:error, :missing_path}
  defp validate_path(_path, false), do: {:ok, nil}
end

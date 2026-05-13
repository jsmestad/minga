defmodule Minga.Distribution.Cookie do
  @moduledoc "Helpers for loading and validating Erlang distribution cookies."

  @allowed_cookie_pattern ~r/^[A-Za-z0-9_.@-]{32,}$/

  @doc "Reads a cookie from a regular 0600-style file."
  @spec read_file(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_file(path) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         :ok <- validate_mode(mode),
         {:ok, content} <- File.read(path) do
      {:ok, String.trim(content)}
    else
      false -> {:error, :insecure_permissions}
      {:ok, %File.Stat{}} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Converts a validated cookie string to an atom for Erlang distribution APIs."
  @spec to_atom(String.t()) :: {:ok, atom()} | {:error, :weak_or_invalid}
  def to_atom(value) when is_binary(value) do
    if valid?(value) do
      {:ok, :erlang.binary_to_atom(value, :utf8)}
    else
      {:error, :weak_or_invalid}
    end
  end

  @doc "Returns true when a cookie has the minimum byte length and allowed characters."
  @spec valid?(String.t()) :: boolean()
  def valid?(value) when is_binary(value) do
    byte_size(value) >= 32 and Regex.match?(@allowed_cookie_pattern, value)
  end

  @spec validate_mode(non_neg_integer()) :: :ok | false
  defp validate_mode(mode) do
    if Bitwise.band(mode, 0o077) == 0, do: :ok, else: false
  end
end

defmodule Minga.Distribution.Config do
  @moduledoc """
  Loads configured remote Minga servers for Erlang distribution.

  The config file is an Elixir term stored at `~/.config/minga/servers.exs`:

      [
        %{name: "home-server", node: :"minga_server@nas.tailnet.ts.net", cookie: :"replace-with-32-plus-random-characters"}
      ]
  """

  @type server_entry :: %{
          name: String.t(),
          node: node(),
          cookie: atom()
        }

  @doc "Loads server entries from the default config path."
  @spec load() :: [server_entry()]
  def load, do: load(default_path())

  @doc "Loads server entries from `path`, returning an empty list when missing or malformed."
  @spec load(String.t()) :: [server_entry()]
  def load(path) when is_binary(path) do
    if File.exists?(path) do
      path
      |> eval_config_file()
      |> normalize_config(path)
    else
      []
    end
  end

  @spec eval_config_file(String.t()) :: {:ok, term()} | {:error, term()}
  defp eval_config_file(path) do
    {term, _binding} = Code.eval_file(path)
    {:ok, term}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec normalize_config({:ok, term()} | {:error, term()}, String.t()) :: [server_entry()]
  defp normalize_config({:ok, entries}, path) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, &validate_entry/2)
    |> validated_entries(path)
  end

  defp normalize_config({:ok, _entries}, path) do
    warn_malformed(path, "expected a list of server maps")
    []
  end

  defp normalize_config({:error, reason}, path) do
    warn_malformed(path, inspect(reason))
    []
  end

  @spec validate_entry(term(), {:ok, [server_entry()]}) ::
          {:cont, {:ok, [server_entry()]}} | {:halt, {:error, String.t()}}
  defp validate_entry(%{name: name, node: node, cookie: cookie}, {:ok, entries})
       when is_binary(name) and is_atom(node) and is_atom(cookie) do
    if strong_cookie?(cookie) do
      normalized = %{name: name, node: node, cookie: cookie}
      {:cont, {:ok, [normalized | entries]}}
    else
      {:halt,
       {:error,
        "invalid server entry: cookie must be at least 32 bytes and contain only letters, numbers, dot, underscore, at, or hyphen"}}
    end
  end

  defp validate_entry(entry, {:ok, _entries}) do
    {:halt, {:error, "invalid server entry: #{inspect(redact_cookie(entry))}"}}
  end

  @spec validated_entries({:ok, [server_entry()]} | {:error, String.t()}, String.t()) :: [
          server_entry()
        ]
  defp validated_entries({:ok, entries}, _path), do: Enum.reverse(entries)

  defp validated_entries({:error, message}, path) do
    warn_malformed(path, message)
    []
  end

  @spec strong_cookie?(atom()) :: boolean()
  defp strong_cookie?(cookie) do
    cookie
    |> Atom.to_string()
    |> Minga.Distribution.Cookie.valid?()
  end

  @spec redact_cookie(term()) :: term()
  defp redact_cookie(entry) when is_map(entry) do
    entry
    |> Map.replace(:cookie, :redacted)
    |> Map.replace("cookie", "redacted")
  end

  defp redact_cookie(entry), do: entry

  @spec default_path() :: String.t()
  defp default_path, do: Path.expand("~/.config/minga/servers.exs")

  @spec warn_malformed(String.t(), String.t()) :: :ok
  defp warn_malformed(path, reason) do
    Minga.Log.warning(:distribution, "Ignoring malformed server config #{path}: #{reason}")
  end
end

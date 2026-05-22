defmodule Minga.Git.DiffOptions do
  @moduledoc false

  @allowed_keys [:path, :staged, :commit]

  @spec validate(keyword()) :: :ok | {:error, String.t()}
  def validate(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- validate_allowed_keys(opts),
         :ok <- validate_duplicate_keys(opts),
         :ok <- validate_types(opts),
         :ok <- validate_commit_staged(opts) do
      :ok
    end
  end

  def validate(_opts), do: {:error, "git diff options must be a keyword list"}

  @spec validate_keyword(keyword()) :: :ok | {:error, String.t()}
  defp validate_keyword(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      {:error, "git diff options must be a keyword list"}
    end
  end

  @spec validate_allowed_keys(keyword()) :: :ok | {:error, String.t()}
  defp validate_allowed_keys(opts) do
    case Enum.find(opts, fn {key, _value} -> key not in @allowed_keys end) do
      nil -> :ok
      {key, _value} -> {:error, "git diff option #{inspect(key)} is not supported"}
    end
  end

  @spec validate_duplicate_keys(keyword()) :: :ok | {:error, String.t()}
  defp validate_duplicate_keys(opts) do
    case duplicate_keys(opts) do
      [] ->
        :ok

      keys ->
        key_list = Enum.map_join(keys, ", ", &inspect/1)
        {:error, "git diff options contain duplicate keys: #{key_list}"}
    end
  end

  @spec validate_types(keyword()) :: :ok | {:error, String.t()}
  defp validate_types([]), do: :ok

  defp validate_types([{:path, path} | rest]) when is_binary(path), do: validate_types(rest)

  defp validate_types([{:path, _path} | _rest]),
    do: {:error, "git diff option :path must be a binary"}

  defp validate_types([{:staged, staged} | rest]) when is_boolean(staged),
    do: validate_types(rest)

  defp validate_types([{:staged, _staged} | _rest]),
    do: {:error, "git diff option :staged must be a boolean"}

  defp validate_types([{:commit, commit} | rest]) when is_binary(commit),
    do: validate_types(rest)

  defp validate_types([{:commit, _commit} | _rest]),
    do: {:error, "git diff option :commit must be a binary"}

  defp validate_types([_other | rest]), do: validate_types(rest)

  @spec validate_commit_staged(keyword()) :: :ok | {:error, String.t()}
  defp validate_commit_staged(opts) do
    if Keyword.get(opts, :commit) != nil and Keyword.get(opts, :staged, false) == true do
      {:error, "git diff options: :commit cannot be combined with :staged"}
    else
      :ok
    end
  end

  @spec duplicate_keys(keyword()) :: [atom()]
  defp duplicate_keys(opts) do
    opts
    |> Enum.frequencies_by(fn {key, _value} -> key end)
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn {key, _count} -> key end)
    |> Enum.filter(&(&1 in @allowed_keys))
  end
end

defmodule MingaAgent.ProjectView.PathResolver do
  @moduledoc false

  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal | :symlink_traversal}
  def resolve(project_root, relative_path, opts \\ [])
      when is_binary(project_root) and is_binary(relative_path) do
    allow_root? = Keyword.get(opts, :allow_root, false)
    root = Path.expand(project_root)

    with {:ok, components} <- validated_components(relative_path, allow_root?) do
      resolve_components(root, root, root, components, allow_root?)
    end
  end

  @spec validated_components(String.t(), boolean()) ::
          {:ok, [String.t()]} | {:error, :invalid_path | :path_traversal}
  defp validated_components(path, allow_root?) do
    components = normalized_components(path)
    reject_invalid_components(path, components, allow_root?)
  end

  @spec reject_invalid_components(String.t(), [String.t()], boolean()) ::
          {:ok, [String.t()]} | {:error, :invalid_path | :path_traversal}
  defp reject_invalid_components(<<"/", _::binary>>, _components, _allow_root?),
    do: {:error, :path_traversal}

  defp reject_invalid_components(_path, components, allow_root?)
       when components == [] and allow_root?,
       do: {:ok, components}

  defp reject_invalid_components(_path, components, _allow_root?) when components == [],
    do: {:error, :invalid_path}

  defp reject_invalid_components(_path, components, _allow_root?) do
    if Enum.member?(components, "..") do
      {:error, :path_traversal}
    else
      {:ok, components}
    end
  end

  @spec resolve_components(String.t(), String.t(), String.t(), [String.t()], boolean()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal | :symlink_traversal}
  defp resolve_components(_root, _validation_current, output_current, [], true),
    do: {:ok, output_current}

  defp resolve_components(_root, _validation_current, _output_current, [], false),
    do: {:error, :invalid_path}

  defp resolve_components(
         root,
         validation_current,
         output_current,
         [component | rest],
         allow_root?
       ) do
    validation_candidate = Path.join(validation_current, component)
    output_candidate = Path.join(output_current, component)

    validation_candidate
    |> File.lstat()
    |> resolve_candidate(root, validation_candidate, output_candidate, rest, allow_root?)
  end

  @spec resolve_candidate(
          {:ok, File.Stat.t()} | {:error, File.posix()},
          String.t(),
          String.t(),
          String.t(),
          [String.t()],
          boolean()
        ) :: {:ok, String.t()} | {:error, term()}
  defp resolve_candidate(
         {:ok, %{type: :symlink}},
         root,
         validation_candidate,
         output_candidate,
         rest,
         allow_root?
       ) do
    with {:ok, resolved} <- resolve_symlink_path(validation_candidate) do
      resolve_symlink_candidate(root, resolved, output_candidate, rest, allow_root?)
    end
  end

  defp resolve_candidate(
         {:ok, %{type: :directory}},
         root,
         validation_candidate,
         output_candidate,
         rest,
         allow_root?
       ) do
    resolve_components(root, validation_candidate, output_candidate, rest, allow_root?)
  end

  defp resolve_candidate(
         {:ok, _stat},
         _root,
         _validation_candidate,
         output_candidate,
         [],
         _allow_root?
       ),
       do: {:ok, output_candidate}

  defp resolve_candidate(
         {:ok, _stat},
         _root,
         _validation_candidate,
         _output_candidate,
         _rest,
         _allow_root?
       ),
       do: {:error, :path_traversal}

  defp resolve_candidate(
         {:error, :enoent},
         _root,
         _validation_candidate,
         output_candidate,
         [],
         _allow_root?
       ),
       do: {:ok, output_candidate}

  defp resolve_candidate(
         {:error, :enoent},
         _root,
         _validation_candidate,
         output_candidate,
         rest,
         _allow_root?
       ),
       do: {:ok, Path.join([output_candidate | rest])}

  defp resolve_candidate(
         {:error, reason},
         _root,
         _validation_candidate,
         _output_candidate,
         _rest,
         _allow_root?
       ),
       do: {:error, reason}

  @spec resolve_symlink_candidate(String.t(), String.t(), String.t(), [String.t()], boolean()) ::
          {:ok, String.t()} | {:error, :symlink_traversal | term()}
  defp resolve_symlink_candidate(root, resolved, output_candidate, [], _allow_root?) do
    if inside_root?(resolved, root),
      do: {:ok, output_candidate},
      else: {:error, :symlink_traversal}
  end

  defp resolve_symlink_candidate(root, resolved, output_candidate, rest, allow_root?) do
    if inside_root?(resolved, root) do
      resolve_components(root, resolved, output_candidate, rest, allow_root?)
    else
      {:error, :symlink_traversal}
    end
  end

  @spec normalized_components(String.t()) :: [String.t()]
  defp normalized_components(path) do
    path
    |> String.trim_leading("./")
    |> Path.split()
    |> Enum.reject(&(&1 in [".", ""]))
  end

  @spec inside_root?(String.t(), String.t()) :: boolean()
  defp inside_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  @spec resolve_symlink_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp resolve_symlink_path(path), do: resolve_symlink_path(path, [])

  @spec resolve_symlink_path(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  defp resolve_symlink_path(path, seen) do
    if path in seen do
      {:error, :symlink_traversal}
    else
      read_symlink_target(path, seen)
    end
  end

  @spec read_symlink_target(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  defp read_symlink_target(path, seen) do
    with {:ok, target} <- File.read_link(path) do
      path
      |> Path.dirname()
      |> resolve_symlink_target(target, seen, path)
    end
  end

  @spec resolve_symlink_target(String.t(), String.t(), [String.t()], String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_symlink_target(dirname, target, seen, path) do
    resolved = Path.expand(target, dirname)

    case File.lstat(resolved) do
      {:ok, %{type: :symlink}} -> resolve_symlink_path(resolved, [path | seen])
      {:ok, _stat} -> {:ok, resolved}
      {:error, reason} -> {:error, reason}
    end
  end
end

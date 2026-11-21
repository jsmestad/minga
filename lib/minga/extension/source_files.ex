defmodule Minga.Extension.SourceFiles do
  @moduledoc """
  Selects the Elixir source files Minga compiles for a path or git extension.

  An extension directory that is a Mix project (it has a `mix.exs`) compiles only `lib/**/*.ex`, the sources Mix itself builds for production. That keeps fetched dependencies in `deps/`, build output in `_build/`, and test support modules out of the editor. A plain directory of `.ex` files compiles every `.ex` file except those under `deps/`, `_build/`, `test/`, or a hidden directory.
  """

  @excluded_dirs ~w(deps _build test)

  @doc "Returns the sorted absolute paths of the source files to compile under `root`."
  @spec list(String.t()) :: [String.t()]
  def list(root) when is_binary(root) do
    root
    |> candidates()
    |> Enum.sort()
  end

  @spec candidates(String.t()) :: [String.t()]
  defp candidates(root) do
    if File.regular?(Path.join(root, "mix.exs")) do
      root |> Path.join("lib/**/*.ex") |> Path.wildcard()
    else
      root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&excluded?(Path.relative_to(&1, root)))
    end
  end

  @spec excluded?(String.t()) :: boolean()
  defp excluded?(relative) do
    relative
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.any?(fn dir -> dir in @excluded_dirs or String.starts_with?(dir, ".") end)
  end
end

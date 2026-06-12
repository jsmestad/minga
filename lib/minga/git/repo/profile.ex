defmodule Minga.Git.Repo.Profile do
  @moduledoc """
  Runtime policy for repo-wide git refreshes.

  The profile is deliberately cheap to build. Ambient editor features use it to avoid expensive status modes in sparse or user-overridden huge repos.
  """

  @type size_class :: :unknown | :large | :huge

  @type t :: %__MODULE__{
          sparse?: boolean(),
          size_class: size_class(),
          untracked_mode: Minga.Git.untracked_mode(),
          timeout_ms: pos_integer()
        }

  @enforce_keys [:sparse?, :size_class, :untracked_mode, :timeout_ms]
  defstruct sparse?: false,
            size_class: :unknown,
            untracked_mode: :normal,
            timeout_ms: 2_000

  @doc "Builds the ambient git policy for `git_root`."
  @spec detect(String.t()) :: t()
  def detect(git_root) when is_binary(git_root) do
    sparse? = sparse_checkout?(git_root)

    %__MODULE__{
      sparse?: sparse?,
      size_class: if(sparse?, do: :large, else: :unknown),
      untracked_mode: if(sparse?, do: :no, else: :normal),
      timeout_ms: 2_000
    }
    |> apply_override(git_root)
  end

  @spec sparse_checkout?(String.t()) :: boolean()
  defp sparse_checkout?(git_root) do
    git_dir = git_dir(git_root)
    sparse_file? = git_dir |> Path.join("info/sparse-checkout") |> File.exists?()
    sparse_config? = git_dir |> Path.join("config") |> sparse_config_enabled?()
    worktree_config? = git_root |> Path.join(".git/config") |> sparse_config_enabled?()
    sparse_file? or sparse_config? or worktree_config?
  end

  @spec git_dir(String.t()) :: String.t()
  defp git_dir(git_root) do
    dot_git = Path.join(git_root, ".git")

    case File.read(dot_git) do
      {:ok, "gitdir: " <> rest} -> Path.expand(String.trim(rest), git_root)
      _ -> dot_git
    end
  end

  @spec sparse_config_enabled?(String.t()) :: boolean()
  defp sparse_config_enabled?(path) do
    case File.read(path) do
      {:ok, config} -> Regex.match?(~r/^\s*sparsecheckout\s*=\s*true\s*$/im, config)
      {:error, _} -> false
    end
  end

  @spec apply_override(t(), String.t()) :: t()
  defp apply_override(%__MODULE__{} = profile, git_root) do
    overrides = Application.get_env(:minga, :git_repo_overrides, %{})
    expanded_root = Path.expand(git_root)

    override =
      Enum.find_value(overrides, %{}, fn {root, value} ->
        if Path.expand(to_string(root)) == expanded_root, do: Map.new(value), else: nil
      end)

    apply_profile_map(profile, override)
  end

  @spec apply_profile_map(t(), map()) :: t()
  defp apply_profile_map(profile, override) when map_size(override) == 0, do: profile

  defp apply_profile_map(profile, override) do
    %{
      profile
      | sparse?: Map.get(override, :sparse?, profile.sparse?),
        size_class: Map.get(override, :size_class, profile.size_class),
        untracked_mode: Map.get(override, :untracked_mode, profile.untracked_mode),
        timeout_ms: Map.get(override, :timeout_ms, profile.timeout_ms)
    }
  end
end

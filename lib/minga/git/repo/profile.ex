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

  # Size proxy: `.git/index` file size.
  #
  # The index file holds one entry per tracked path (roughly a few dozen bytes
  # each: mode, sha, flags, and the path string). Its size therefore scales with
  # the tracked-file count, which is the cost driver for `git status`. Reading a
  # single `File.stat` is O(1) and adds no filesystem walk at startup, so it is a
  # cheap stand-in for "how big is this working tree" without enumerating it.
  #
  # Thresholds are heuristic, picked from observed index sizes (~80-100 bytes per
  # entry): ~10 MB ≈ 100k+ tracked files (huge), ~2 MB ≈ 20k+ (large). They are
  # intentionally conservative and only affect the bounded `timeout_ms`, never
  # whether untracked files are hidden.
  @huge_index_bytes 10 * 1024 * 1024
  @large_index_bytes 2 * 1024 * 1024

  # Bounded timeouts per size class. Larger repos get a longer (still bounded)
  # budget so a normal status has a chance to finish before degrading.
  @huge_timeout_ms 4_000
  @large_timeout_ms 3_000
  @default_timeout_ms 2_000

  @doc "Builds the ambient git policy for `git_root`."
  @spec detect(String.t()) :: t()
  def detect(git_root) when is_binary(git_root) do
    sparse? = sparse_checkout?(git_root)

    sparse?
    |> base_profile(git_root)
    |> apply_override(git_root)
  end

  # Sparse checkouts keep the conservative `:no` untracked mode (AC 3): the
  # checkout deliberately omits paths, so enumerating untracked files is both
  # expensive and misleading.
  @spec base_profile(boolean(), String.t()) :: t()
  defp base_profile(true, _git_root) do
    %__MODULE__{
      sparse?: true,
      size_class: :large,
      untracked_mode: :no,
      timeout_ms: @default_timeout_ms
    }
  end

  # Non-sparse (full) checkouts classify by index size and ALWAYS keep
  # `untracked_mode: :normal` (AC 2). A huge repo must never silently fall back
  # to `:no`, which would hide untracked files; instead it degrades visibly when
  # the bounded timeout trims results.
  defp base_profile(false, git_root) do
    size_class = classify_size(git_root)

    %__MODULE__{
      sparse?: false,
      size_class: size_class,
      untracked_mode: :normal,
      timeout_ms: timeout_for_size(size_class)
    }
  end

  @spec classify_size(String.t()) :: size_class()
  defp classify_size(git_root) do
    case index_size(git_root) do
      bytes when bytes >= @huge_index_bytes -> :huge
      bytes when bytes >= @large_index_bytes -> :large
      _bytes -> :unknown
    end
  end

  # Returns the `.git/index` size in bytes, or 0 when it cannot be read (no
  # index yet, permissions, or a worktree without one). 0 classifies as
  # `:unknown`, the safe default.
  @spec index_size(String.t()) :: non_neg_integer()
  defp index_size(git_root) do
    case git_root |> git_dir() |> Path.join("index") |> File.stat() do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end

  @spec timeout_for_size(size_class()) :: pos_integer()
  defp timeout_for_size(:huge), do: @huge_timeout_ms
  defp timeout_for_size(:large), do: @large_timeout_ms
  defp timeout_for_size(_size_class), do: @default_timeout_ms

  @doc """
  Returns true when this profile still enumerates untracked files (`:normal`).

  A status timeout on such a profile means results were trimmed while untracked
  files were in scope, so the omission must be surfaced as degraded (AC 2/5).
  Sparse / `:no` profiles deliberately omit untracked files, so a timeout there
  is not a visibility regression worth flagging.
  """
  @spec degrades_visibly?(t()) :: boolean()
  def degrades_visibly?(%__MODULE__{untracked_mode: :normal}), do: true
  def degrades_visibly?(%__MODULE__{}), do: false

  @doc """
  Returns the absolute path of the sole sparse-checkout leaf cone directory, or `nil`.

  In cone mode the sparse-checkout file lists each included directory as a
  `/dir/` line, alongside the `/*` and `!/*/` preamble that keeps root files and
  excludes everything else. Parent scaffolding lines such as `!/apps/*/` are
  ignored, so a nested checkout like `apps/web` resolves to the leaf cone only.
  Any non-empty line outside those cone forms makes the file non-cone, so
  callers keep git-root / nearest-marker behavior.
  """
  @spec single_cone_dir(String.t()) :: String.t() | nil
  def single_cone_dir(git_root) when is_binary(git_root) do
    case cone_dirs(git_root) do
      [dir] -> Path.join(git_root, dir)
      _ -> nil
    end
  end

  @spec cone_dirs(String.t()) :: [String.t()]
  defp cone_dirs(git_root) do
    path = git_root |> git_dir() |> Path.join("info/sparse-checkout")

    case File.read(path) do
      {:ok, content} ->
        lines = content |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

        if cone_mode_file?(lines) do
          scaffold_dirs = lines |> Enum.flat_map(&cone_scaffold_dir/1) |> MapSet.new()

          lines
          |> Enum.flat_map(&cone_dir/1)
          |> Enum.reject(&MapSet.member?(scaffold_dirs, &1))
        else
          []
        end

      {:error, _reason} ->
        []
    end
  end

  @spec cone_mode_file?([String.t()]) :: boolean()
  defp cone_mode_file?(lines) do
    "/*" in lines and "!/*/" in lines and Enum.all?(lines, &cone_line?/1)
  end

  @spec cone_line?(String.t()) :: boolean()
  defp cone_line?("/*"), do: true
  defp cone_line?("!/*/"), do: true

  defp cone_line?("!/" <> rest) do
    path = String.trim_trailing(rest, "/*/")
    String.ends_with?(rest, "/*/") and path != "" and not String.contains?(path, ["*", "?", "["])
  end

  defp cone_line?("/" <> rest) do
    String.ends_with?(rest, "/") and rest != "" and not String.contains?(rest, ["*", "?", "["])
  end

  defp cone_line?(_), do: false

  # Cone-mode directory entries look like `/path/`.
  @spec cone_dir(String.t()) :: [String.t()]
  defp cone_dir("/*"), do: []
  defp cone_dir("!/*/"), do: []
  defp cone_dir("!/" <> _), do: []

  defp cone_dir("/" <> _ = line) do
    if String.ends_with?(line, "/"), do: [String.trim(line, "/")], else: []
  end

  defp cone_dir(_), do: []

  # Nested cone scaffolding lines look like `!/apps/*/`.
  @spec cone_scaffold_dir(String.t()) :: [String.t()]
  defp cone_scaffold_dir("!/" <> rest) do
    case String.trim_trailing(rest, "/*/") do
      ^rest -> []
      "" -> []
      dir -> [String.trim_leading(dir, "/")]
    end
  end

  defp cone_scaffold_dir(_), do: []

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

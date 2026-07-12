defmodule Minga.Git.Repo.ProfileTest do
  @moduledoc "Tests for repo refresh policy detection."
  use ExUnit.Case, async: true

  alias Minga.Git.Repo.Profile

  @moduletag :tmp_dir

  # Index sizes just past the heuristic thresholds (2 MB large, 10 MB huge).
  @large_index_bytes 2 * 1024 * 1024
  @huge_index_bytes 10 * 1024 * 1024

  test "defaults to normal untracked mode for ordinary repos", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))

    profile = Profile.detect(dir)

    refute profile.sparse?
    assert profile.size_class == :unknown
    assert profile.untracked_mode == :normal
    assert profile.timeout_ms == 2_000
  end

  test "classifies a large full checkout from index size but keeps bounded normal mode",
       %{tmp_dir: dir} do
    write_index(dir, @large_index_bytes)

    profile = Profile.detect(dir)

    refute profile.sparse?
    assert profile.size_class == :large
    # AC 2: a large full checkout degrades to a bounded :normal, never :no.
    assert profile.untracked_mode == :normal
    assert profile.timeout_ms == 3_000
  end

  test "classifies a huge full checkout with a larger but bounded timeout", %{tmp_dir: dir} do
    write_index(dir, @huge_index_bytes)

    profile = Profile.detect(dir)

    assert profile.size_class == :huge
    assert profile.untracked_mode == :normal
    assert profile.timeout_ms == 4_000
  end

  test "resolves a gitdir pointer file when sizing the index", %{tmp_dir: dir} do
    # Worktree-style `.git` file pointing at the real git dir elsewhere.
    real_git_dir = Path.join(dir, "real-git-dir")
    File.mkdir_p!(real_git_dir)
    File.write!(Path.join(real_git_dir, "index"), :binary.copy(<<0>>, @huge_index_bytes))

    File.write!(Path.join(dir, ".git"), "gitdir: #{real_git_dir}\n")

    profile = Profile.detect(dir)

    assert profile.size_class == :huge
  end

  test "degrades_visibly? is true for normal full checkouts and false for sparse :no" do
    full = %Profile{sparse?: false, size_class: :huge, untracked_mode: :normal, timeout_ms: 4_000}
    sparse = %Profile{sparse?: true, size_class: :large, untracked_mode: :no, timeout_ms: 3_000}

    assert Profile.degrades_visibly?(full)
    refute Profile.degrades_visibly?(sparse)
  end

  test "uses no untracked enumeration for sparse repos", %{tmp_dir: dir} do
    sparse_file = Path.join([dir, ".git", "info", "sparse-checkout"])
    File.mkdir_p!(Path.dirname(sparse_file))
    File.write!(sparse_file, "lib/\n")

    profile = Profile.detect(dir)

    assert profile.sparse?
    assert profile.size_class == :large
    assert profile.untracked_mode == :no
  end

  describe "single_cone_dir/1" do
    test "returns the leaf cone for a nested single-cone sparse checkout", %{tmp_dir: dir} do
      write_sparse_checkout(dir, "/*\n!/*/\n/apps/\n!/apps/*/\n/apps/web/\n")

      assert Profile.single_cone_dir(dir) == Path.join(dir, "apps/web")
    end

    test "returns nil for a multi-leaf cone", %{tmp_dir: dir} do
      write_sparse_checkout(dir, "/*\n!/*/\n/apps/\n!/apps/*/\n/apps/web/\n/apps/api/\n")

      assert Profile.single_cone_dir(dir) == nil
    end

    test "returns nil for a non-cone sparse pattern file with cone-like preamble", %{tmp_dir: dir} do
      write_sparse_checkout(dir, "/*\n!/*/\n/apps/\n/apps/web/**/*.ex\n")

      assert Profile.single_cone_dir(dir) == nil
    end

    test "returns nil when there is no sparse-checkout file", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))

      assert Profile.single_cone_dir(dir) == nil
    end

    test "returns nil for a cone with only the preamble (no directories)", %{tmp_dir: dir} do
      write_sparse_checkout(dir, "/*\n!/*/\n")

      assert Profile.single_cone_dir(dir) == nil
    end
  end

  @spec write_sparse_checkout(String.t(), String.t()) :: :ok
  defp write_sparse_checkout(dir, content) do
    sparse_file = Path.join([dir, ".git", "info", "sparse-checkout"])
    File.mkdir_p!(Path.dirname(sparse_file))
    File.write!(sparse_file, content)
  end

  # Writes a `.git/index` of the given byte size so size classification has a
  # cheap proxy to read via File.stat.
  @spec write_index(String.t(), non_neg_integer()) :: :ok
  defp write_index(dir, bytes) do
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join([dir, ".git", "index"]), :binary.copy(<<0>>, bytes))
  end
end

defmodule Minga.Git.Repo.ProfileTest do
  @moduledoc "Tests for repo refresh policy detection."
  # Mutates Application env for the override test, so this module must run serially.
  use ExUnit.Case, async: false

  alias Minga.Git.Repo.Profile

  @moduletag :tmp_dir

  test "defaults to normal untracked mode for ordinary repos", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))

    profile = Profile.detect(dir)

    refute profile.sparse?
    assert profile.size_class == :unknown
    assert profile.untracked_mode == :normal
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

  test "applies per-repo config overrides", %{tmp_dir: dir} do
    old = Application.get_env(:minga, :git_repo_overrides)

    Application.put_env(:minga, :git_repo_overrides, %{
      dir => %{sparse?: true, size_class: :huge, untracked_mode: :all, timeout_ms: 123}
    })

    on_exit(fn -> restore_overrides(old) end)

    File.mkdir_p!(Path.join(dir, ".git"))

    profile = Profile.detect(dir)

    assert profile.sparse?
    assert profile.size_class == :huge
    assert profile.untracked_mode == :all
    assert profile.timeout_ms == 123
  end

  @spec restore_overrides(term()) :: :ok
  defp restore_overrides(nil), do: Application.delete_env(:minga, :git_repo_overrides)
  defp restore_overrides(value), do: Application.put_env(:minga, :git_repo_overrides, value)
end

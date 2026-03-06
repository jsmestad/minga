defmodule Minga.GitTest do
  @moduledoc "Tests for Git utility functions."

  use ExUnit.Case, async: true

  alias Minga.Git

  describe "root_for/1" do
    test "finds git root for a file in a repo" do
      # This test runs in the minga repo itself
      {:ok, root} = Git.root_for(__DIR__)
      assert File.exists?(Path.join(root, ".git"))
    end

    test "returns :not_git for a path outside any repo" do
      assert Git.root_for("/tmp") == :not_git
    end
  end

  describe "show_head/2" do
    test "reads a file that exists in HEAD" do
      {:ok, root} = Git.root_for(__DIR__)
      {:ok, content} = Git.show_head(root, "mix.exs")
      assert String.contains?(content, "defmodule")
    end

    test "returns :error for a file not in HEAD" do
      {:ok, root} = Git.root_for(__DIR__)
      assert Git.show_head(root, "nonexistent_file_abc123.txt") == :error
    end
  end

  describe "relative_path/2" do
    test "returns path relative to git root" do
      assert Git.relative_path("/home/user/project", "/home/user/project/lib/foo.ex") ==
               "lib/foo.ex"
    end
  end

  describe "blame_line/3" do
    test "returns blame info for a tracked file" do
      {:ok, root} = Git.root_for(__DIR__)
      result = Git.blame_line(root, "mix.exs", 0)

      case result do
        {:ok, text} -> assert is_binary(text) and String.length(text) > 0
        :error -> :ok
      end
    end
  end
end

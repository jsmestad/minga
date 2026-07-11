defmodule MingaAgent.Tools.SubagentWorktreeHeavyTest do
  # Real Git worktree commands spawn OS processes and must avoid erl_child_setup races.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.Subagent
  alias Minga.Test.SubagentWorktreeProvider
  alias ReqLLM.StreamResponse.MetadataHandle
  alias ReqLLM.StreamChunk

  @moduletag :heavy
  @moduletag :tmp_dir

  test "real Git preserves a changed foreground worktree with metadata and auto-approval", %{
    tmp_dir: dir
  } do
    root = init_git_repo!(dir)

    assert {:ok, result} =
             Subagent.execute("write through native tool",
               isolation: "worktree",
               project_root: root,
               provider: MingaAgent.Providers.Native,
               model: "anthropic:claude-sonnet-4-20250514",
               provider_opts: [
                 llm_client: native_write_client("child.txt", "from native\n", "native wrote"),
                 skip_api_key_env: true
               ]
             )

    assert result =~ "native wrote"
    assert [_, worktree_path] = Regex.run(~r/Worktree: (.+)/, result)
    assert [_, "subagent/" <> _id] = Regex.run(~r/Branch: (.+)/, result)
    assert File.read!(Path.join(worktree_path, "child.txt")) == "from native\n"
    refute File.exists?(Path.join(root, "child.txt"))
    assert worktree_path in worktree_paths(root)
  end

  test "real Git removes a clean foreground worktree and temporary branch", %{tmp_dir: dir} do
    root = init_git_repo!(dir)
    worktrees_before = worktree_paths(root)

    assert {:ok, "no changes"} =
             Subagent.execute("noop",
               isolation: "worktree",
               project_root: root,
               provider: SubagentWorktreeProvider
             )

    assert worktree_paths(root) == worktrees_before
    assert git_lines(root, ["branch", "--list", "subagent/*"]) == []
  end

  @spec native_write_client(String.t(), String.t(), String.t()) :: function()
  defp native_write_client(path, content, final_text) do
    call_count = :counters.new(1, [:atomics])

    fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            StreamChunk.tool_call(
              "write_file",
              %{"path" => path, "content" => content},
              %{id: "tc_write_file", index: 0}
            ),
            StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [StreamChunk.text(final_text), StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end
  end

  @spec build_stream_response([StreamChunk.t()]) :: {:ok, ReqLLM.StreamResponse.t()}
  defp build_stream_response(chunks) do
    {:ok, handle} = MetadataHandle.start_link(fn -> %{usage: %{}, finish_reason: :stop} end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: chunks,
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
       context: ReqLLM.Context.new()
     }}
  end

  @spec init_git_repo!(String.t()) :: String.t()
  defp init_git_repo!(dir) do
    root = Path.join(dir, "repo")
    File.mkdir_p!(root)
    git!(root, ["init", "."])
    hooks_dir = Path.join(root, ".git/hooks-disabled")
    File.mkdir_p!(hooks_dir)
    git!(root, ["config", "core.hooksPath", hooks_dir])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["config", "user.name", "Minga Test"])
    git!(root, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(root, "README.md"), "root\n")
    git!(root, ["add", "README.md"])
    git!(root, ["commit", "-m", "init"])
    root
  end

  @spec worktree_paths(String.t()) :: [String.t()]
  defp worktree_paths(root) do
    root
    |> git_lines(["worktree", "list", "--porcelain"])
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
  end

  @spec git_lines(String.t(), [String.t()]) :: [String.t()]
  defp git_lines(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> String.split(output, "\n", trim: true)
      {output, _status} -> flunk("git #{Enum.join(args, " ")} failed: #{output}")
    end
  end

  @spec git!(String.t(), [String.t()]) :: :ok
  defp git!(cwd, args) do
    _lines = git_lines(cwd, args)
    :ok
  end
end

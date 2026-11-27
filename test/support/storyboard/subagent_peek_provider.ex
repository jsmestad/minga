defmodule Minga.Test.Storyboard.SubagentPeekProvider do
  @moduledoc false

  alias MingaAgent.Test.ModelSelectionFixture
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse.MetadataHandle

  @subagents [
    "Editorial and Jargon Roaster",
    "Fact-Check Auditor",
    "Competitive Fairness Critic",
    "Technical Change Skeptic"
  ]
  @sources ["index.html", "guide.html", "compare.html"]
  @brief "Review the site as a skeptical reader. Find unclear jargon and comparisons without evidence."
  @report "Lead with what the editor does for the reader. Replace unsupported comparisons with measured startup numbers."

  @spec opts() :: keyword()
  def opts do
    [
      model_resolver_opts: ModelSelectionFixture.resolver_opts(display_name: "Offline review"),
      credential_opts: [env: %{"OPENAI_API_KEY" => "fixture-openai-key"}],
      config: %MingaAgent.Config{compaction_threshold: nil, tool_approval: :none},
      skip_api_key_env: true,
      max_retries: 0,
      llm_client: &respond/3
    ]
  end

  @spec prepare_files(Path.t()) :: :ok
  def prepare_files(root) do
    for path <- @sources do
      File.write!(Path.join(root, path), "<p>Start fast on your first edit.</p>\n")
    end

    :ok
  end

  @spec respond(LLMDB.Model.t(), [ReqLLM.Message.t()], keyword()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  defp respond(model, messages, _opts) do
    user = Enum.find(Enum.reverse(messages), &(&1.role == :user))

    prompt =
      if user, do: for(%{type: :text, text: text} <- user.content, into: "", do: text), else: ""

    last = List.last(messages).role

    cond do
      String.starts_with?(prompt, "Review the marketing site") -> respond_as_parent(model, last)
      String.starts_with?(prompt, hd(@subagents)) -> respond_as_reviewer(model, last)
      Enum.any?(tl(@subagents), &String.starts_with?(prompt, &1)) -> hold_next_report()
      true -> stream(model, [StreamChunk.text("Follow-up received by this subagent.")], :stop)
    end
  end

  @spec respond_as_parent(LLMDB.Model.t(), atom()) :: {:ok, ReqLLM.StreamResponse.t()}
  defp respond_as_parent(model, :user) do
    calls =
      for {title, index} <- Enum.with_index(@subagents, 1) do
        StreamChunk.tool_call("subagent", %{"task" => title <> "\n" <> @brief}, %{
          id: "site-review-#{index}"
        })
      end

    opening =
      StreamChunk.text(
        "I will check facts, fairness, jargon and what a skeptical reader needs to see."
      )

    stream(model, [opening | calls], :tool_use)
  end

  defp respond_as_parent(model, _role),
    do: stream(model, [StreamChunk.text("Review complete.")], :stop)

  @spec respond_as_reviewer(LLMDB.Model.t(), atom()) :: {:ok, ReqLLM.StreamResponse.t()}
  defp respond_as_reviewer(model, :user) do
    calls =
      for {path, index} <- Enum.with_index(@sources, 1) do
        StreamChunk.tool_call("read_file", %{"path" => path}, %{id: "site-source-#{index}"})
      end

    stream(model, calls, :tool_use)
  end

  defp respond_as_reviewer(model, _role), do: stream(model, [StreamChunk.text(@report)], :stop)

  # The Native provider owns and cancels this fetch when the fixture stops its parent. Keeping the next report pending makes the first real handback observable.
  @spec hold_next_report() :: {:error, term()}
  defp hold_next_report do
    receive do
      :fixture_closed -> {:error, :fixture_closed}
    after
      30_000 -> {:error, :fixture_expired}
    end
  end

  @spec stream(LLMDB.Model.t(), [StreamChunk.t()], atom()) :: {:ok, ReqLLM.StreamResponse.t()}
  defp stream(model, chunks, reason) do
    {:ok, handle} = MetadataHandle.start_link(fn -> %{usage: %{}, finish_reason: :stop} end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: chunks ++ [StreamChunk.meta(%{finish_reason: reason})],
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: model,
       context: ReqLLM.Context.new()
     }}
  end
end

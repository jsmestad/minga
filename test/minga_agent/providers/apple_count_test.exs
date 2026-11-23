defmodule MingaAgent.Providers.AppleCountTest do
  # Spawns the real Apple Intelligence helper as an OS process.
  use ExUnit.Case, async: false

  alias MingaAgent.Providers.Apple
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias MingaAgent.Tools
  alias ReqLLM.Context

  @moduletag :apple_inference

  setup_all do
    case Apple.availability() do
      {:ok, _context} -> :ok
      {:error, reason} -> flunk("MINGA_APPLE_INFERENCE=1 needs a ready Apple model: #{reason}")
    end
  end

  defp apple_tools do
    Tools.all()
    |> Enum.filter(&(&1.name in ~w(read_file find grep edit_file write_file)))
    |> Enum.map(&ReqLLMAdapter.tool(&1, :registry))
  end

  test "count separates the fixed prefix from the transcript without generating" do
    tools = apple_tools()
    system = Context.system("You are an AI coding assistant inside Minga.")

    assert {:ok, %{instructions: prefix, transcript: total, context: context}} =
             Apple.count([system, Context.user("hi")], tools, 512)

    assert prefix > 0 and prefix < total
    assert context > 0

    assert {:ok, %{instructions: longer_prefix, transcript: longer_total}} =
             Apple.count([system, Context.user(String.duplicate("word ", 200))], tools, 512)

    # Only the prompt grew, so only the transcript count moved.
    assert longer_prefix == prefix
    assert longer_total > total

    assert {:ok, %{instructions: 0, transcript: bare}} =
             Apple.count([Context.user("hi")], [], 512)

    assert bare > 0
  end

  test "one count_prefixes call counts every candidate within the preview deadline" do
    parts = [
      "You are an AI coding assistant inside Minga.",
      "Use a tool only when needed.",
      File.read!(Path.expand("AGENTS.md"))
    ]

    tools = apple_tools()

    {elapsed, result} =
      :timer.tc(
        fn -> Apple.count_prefixes(parts, [[0, 1], [0, 1, 2]], tools, 512) end,
        :millisecond
      )

    assert {:ok, %{counts: [required, full], context: context}} = result
    assert required < context and full > context

    # Native refuses a count that takes longer than 3 s; a cold start of this case is well inside it.
    assert elapsed < 3_000

    # The candidate equals the same prompt sent as an inference's single system message.
    assert {:ok, %{instructions: ^required}} =
             Apple.count(
               [Context.system(Enum.join(Enum.take(parts, 2), "\n\n")), Context.user("")],
               tools,
               512
             )
  end

  test "count measures a prefix far beyond the context instead of refusing it" do
    instructions = String.duplicate("Always follow this project rule exactly.\n", 1_500)

    assert {:ok, %{instructions: prefix, context: context}} =
             Apple.count([Context.system(instructions), Context.user("")], apple_tools(), 512)

    assert prefix > context
  end
end

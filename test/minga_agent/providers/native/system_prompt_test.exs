defmodule MingaAgent.Providers.Native.SystemPromptTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Providers.Native.SystemPrompt

  # Apple's shape: 4,096 context, 512 reserved for output, 1,536 kept free for history.
  @budget %{reserve: 512, history_floor: 1_536}

  # One token per byte of the joined candidate keeps each case's arithmetic visible.
  defp measure(texts, candidates) do
    counts =
      for candidate <- candidates,
          do: candidate |> Enum.map_join("\n\n", &Enum.at(texts, &1)) |> byte_size()

    {:ok, %{counts: counts, context: 4_096}}
  end

  defp bytes(n), do: String.duplicate("x", n)

  describe "fit/3 sends optional parts only while the measured prefix leaves the history floor" do
    for {name, optional, expected_omitted} <- [
          {"no optional parts", [], []},
          {"small instructions", [instructions: 400], []},
          {"oversized instructions", [instructions: 17_750], [:instructions]},
          {"oversized instructions keep a small append prompt",
           [instructions: 17_750, append_prompt: 100], [:instructions]},
          {"each part is judged in order against what already fits",
           [instructions: 500, skills: 700, append_prompt: 100], [:skills]},
          {"everything optional omitted",
           [instructions: 1_100, skills: 1_100, append_prompt: 1_100],
           [:instructions, :skills, :append_prompt]}
        ] do
      test name do
        optional = Enum.map(unquote(optional), fn {part, n} -> {part, bytes(n)} end)
        parts = SystemPrompt.new([bytes(1_000)], optional)

        assert {:ok, fit} = SystemPrompt.fit(parts, @budget, &measure/2)
        assert fit.omitted == unquote(expected_omitted)
        assert fit.prefix == byte_size(fit.text)
        assert fit.prefix + 512 + 1_536 <= 4_096

        sent = for {part, text} <- optional, part not in fit.omitted, do: text
        assert fit.text == Enum.join([bytes(1_000) | sent], "\n\n")
      end
    end
  end

  test "a required prefix above the floor is still sent when it leaves room for the reserve" do
    parts = SystemPrompt.new([bytes(3_000)], instructions: "rules")

    assert {:ok, %{omitted: [:instructions], prefix: 3_000}} =
             SystemPrompt.fit(parts, @budget, &measure/2)
  end

  test "a required prefix that leaves no room for the reserve is refused with its counts" do
    parts = SystemPrompt.new([bytes(3_700)], instructions: bytes(17_750))

    assert {:error,
            {:fixed_prefix_exceeded, %{prefix: 3_700, history: 0, reserve: 512, context: 4_096}}} =
             SystemPrompt.fit(parts, @budget, &measure/2)
  end

  test "an optional part too large to encode is omitted, but a required one is an error" do
    measure = fn texts, candidates ->
      if texts |> Enum.map(&byte_size/1) |> Enum.sum() > 10_000,
        do: {:error, :oversized_apple_request},
        else: measure(texts, candidates)
    end

    parts = SystemPrompt.new(["base"], instructions: bytes(20_000))

    assert {:ok, %{omitted: [:instructions], text: "base"}} =
             SystemPrompt.fit(parts, @budget, measure)

    assert {:error, :oversized_apple_request} =
             SystemPrompt.fit(SystemPrompt.new([bytes(20_000)], []), @budget, measure)
  end

  test "every in-order combination is counted in one measurement" do
    owner = self()

    measure = fn texts, candidates ->
      send(owner, {:measured, texts, candidates})
      measure(texts, candidates)
    end

    parts =
      SystemPrompt.new(["base"], instructions: "rules", skills: "skill", append_prompt: "tail")

    assert {:ok, %{omitted: []}} = SystemPrompt.fit(parts, @budget, measure)

    assert_received {:measured, ["base", "rules", "skill", "tail"], candidates}
    refute_received {:measured, _texts, _candidates}

    assert Enum.sort(candidates) ==
             Enum.sort([
               [0],
               [0, 1],
               [0, 2],
               [0, 3],
               [0, 1, 2],
               [0, 1, 3],
               [0, 2, 3],
               [0, 1, 2, 3]
             ])
  end

  test "a counting failure is returned rather than guessed around" do
    parts = SystemPrompt.new(["base"], instructions: "rules")

    assert {:error, :helper_missing} =
             SystemPrompt.fit(parts, @budget, fn _texts, _candidates ->
               {:error, :helper_missing}
             end)
  end

  test "unbounded composition sends every non-empty part in order" do
    parts =
      SystemPrompt.new(["base", nil, "guide"],
        instructions: "rules",
        skills: "",
        append_prompt: "tail"
      )

    assert SystemPrompt.unbounded(parts) == %{
             text: "base\n\nguide\n\nrules\n\ntail",
             omitted: [],
             prefix: nil,
             context: nil
           }
  end
end

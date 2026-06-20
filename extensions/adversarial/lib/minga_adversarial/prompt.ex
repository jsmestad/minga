defmodule MingaAdversarial.Prompt do
  @moduledoc """
  Builds the adversarial chat messages.

  The model is asked to find the assumptions a piece of code makes that could
  break, tied to specific lines, and to answer with a strict JSON array so the
  result is machine-parseable. The skepticism tier only swaps one phrase: how
  aggressively to flag.
  """

  @type skepticism :: :off | :manual | :on_save | :paranoid

  @max_findings 12

  @spec messages(String.t(), String.t(), skepticism()) :: [
          %{role: String.t(), content: String.t()}
        ]
  def messages(path, content, skepticism) do
    [
      %{role: "system", content: system(skepticism)},
      %{role: "user", content: user(path, content)}
    ]
  end

  @spec system(skepticism()) :: String.t()
  defp system(skepticism) do
    """
    You are an adversarial pair programmer. You are not hostile; you are a sharp
    sparring partner. Your job is to find the assumptions this code makes that
    could break: unhandled empty/nil inputs, unproven performance claims,
    unguarded error paths, off-by-one and boundary cases, race conditions, and
    reliance on invariants that callers may violate.

    #{tier_phrase(skepticism)}

    Respond with ONLY a JSON array, no prose, no code fences. Each element is
    an object {"line": <1-based line number>, "concern": "<one sentence>"}.
    Cite the most specific line you can. Return [] if you find nothing worth
    flagging. Return at most #{@max_findings} of the most important findings.
    """
  end

  @spec tier_phrase(skepticism()) :: String.t()
  defp tier_phrase(:paranoid),
    do:
      "Be maximally skeptical. Flag every questionable assumption and edge case, " <>
        "even minor ones."

  defp tier_phrase(_other),
    do: "Focus on the most consequential hidden assumptions and failure modes. Skip nitpicks."

  @spec user(String.t(), String.t()) :: String.t()
  defp user(path, content) do
    "File: #{path}\n\n" <> number_lines(content)
  end

  @spec number_lines(String.t()) :: String.t()
  defp number_lines(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {line, n} -> "#{n}: #{line}" end)
  end
end

defmodule MingaAdversarial.PromptTest do
  use ExUnit.Case, async: true

  alias MingaAdversarial.Prompt

  defp user_content(content, skepticism \\ :manual) do
    [_system, %{role: "user", content: text}] = Prompt.messages("/x.ex", content, skepticism)
    text
  end

  test "numbers the real lines and drops the trailing-newline artifact" do
    content = user_content("alpha\nbeta\n")
    assert content =~ "1: alpha"
    assert content =~ "2: beta"
    refute content =~ "3:"
  end

  test "keeps a genuine trailing blank line (a double newline)" do
    content = user_content("alpha\nbeta\n\n")
    assert content =~ "3: "
    refute content =~ "4:"
  end

  test "paranoid tier swaps in the maximally-skeptical phrasing" do
    [%{role: "system", content: sys}, _user] = Prompt.messages("/x.ex", "code", :paranoid)
    assert sys =~ "maximally skeptical"
  end
end

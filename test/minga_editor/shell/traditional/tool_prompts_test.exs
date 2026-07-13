defmodule MingaEditor.Shell.Traditional.ToolPromptsTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.ToolPrompts

  test "queue, decline decisions, and suppression stay coherent" do
    prompts =
      %ToolPrompts{}
      |> ToolPrompts.enqueue(:ripgrep)
      |> ToolPrompts.enqueue(:ripgrep)
      |> ToolPrompts.enqueue(:zls)
      |> ToolPrompts.suppress(true)

    assert ToolPrompts.queue(prompts) == [:ripgrep, :zls]
    assert ToolPrompts.decided?(prompts, :ripgrep)
    assert ToolPrompts.suppressed?(prompts)

    prompts = ToolPrompts.replace(prompts, [:zls], MapSet.new([:ripgrep]))
    assert ToolPrompts.decided?(prompts, :ripgrep)
    assert ToolPrompts.queue(ToolPrompts.advance(prompts)) == []
  end
end

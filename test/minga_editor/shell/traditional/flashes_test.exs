defmodule MingaEditor.Shell.Traditional.FlashesTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.Flashes
  alias MingaEditor.Shell.Traditional.FlashesWorkflow
  alias MingaEditor.Shell.Traditional.NavFlash
  alias MingaEditor.Shell.Traditional.YankFlash

  import MingaEditor.RenderPipeline.TestHelpers

  test "navigation and yank flashes coexist and replace independently" do
    flashes =
      %Flashes{}
      |> Flashes.replace_nav(12)
      |> Flashes.replace_yank(self(), {1, 0}, {1, 5}, :charwise)

    assert NavFlash.active?(flashes.nav)
    assert YankFlash.active?(flashes.yank)
    yank = flashes.yank

    replaced = Flashes.replace_nav(flashes, 30)
    assert replaced.nav.generation == flashes.nav.generation + 1
    assert replaced.yank == yank

    canceled = Flashes.cancel_yank(replaced)
    assert NavFlash.active?(canceled.nav)
    refute YankFlash.active?(canceled.yank)
  end

  test "Editor animation messages cannot advance a replacement generation" do
    first = FlashesWorkflow.replace_nav(base_state(), 12)
    first_generation = first.shell_runtime.state.flashes.nav.generation
    replacement = FlashesWorkflow.replace_nav(first, 30)

    assert {:noreply, stale_delivery} =
             MingaEditor.handle_info({:nav_flash_step, first_generation}, replacement)

    assert stale_delivery.shell_runtime.state.flashes == replacement.shell_runtime.state.flashes
  end

  test "stale generations affect neither leaf" do
    flashes =
      %Flashes{}
      |> Flashes.replace_nav(12)
      |> Flashes.replace_yank(self(), {1, 0}, {1, 5}, :charwise)

    assert {:stale, unchanged} = Flashes.advance_nav(flashes, 0)
    assert unchanged == flashes
    assert {:stale, unchanged} = Flashes.advance_yank(flashes, 0)
    assert unchanged == flashes
  end
end

Code.require_file("credo/checks/no_direct_modal_overlay_write_check.exs")

defmodule Minga.Credo.NoDirectModalOverlayWriteCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.NoDirectModalOverlayWriteCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source_code, filename) do
    source_code
    |> to_source_file(filename)
    |> run_check(NoDirectModalOverlayWriteCheck, [])
  end

  test "flags direct modal map updates" do
    """
    defmodule MingaEditor.BadModalWriter do
      def close(shell_state) do
        %{shell_state | modal: :none}
      end
    end
    """
    |> check("lib/minga_editor/bad_modal_writer.ex")
    |> assert_issue(fn issue ->
      assert issue.message =~ "Direct write to `modal:`"
      assert issue.message =~ "ModalOverlay"
    end)
  end

  test "flags direct modal struct updates" do
    """
    defmodule MingaEditor.BadModalStructWriter do
      def close(shell_state) do
        %MingaEditor.Shell.Traditional.State{shell_state | modal: :none}
      end
    end
    """
    |> check("lib/minga_editor/bad_modal_struct_writer.ex")
    |> assert_issue(fn issue ->
      assert issue.trigger == "modal:"
    end)
  end

  test "allows the modal overlay gate" do
    """
    defmodule MingaEditor.State.ModalOverlay do
      def close(state) do
        %{state.shell_state | modal: :none}
      end
    end
    """
    |> check("lib/minga_editor/state/modal_overlay.ex")
    |> refute_issues()
  end

  test "allows shell state owner modules" do
    """
    defmodule MingaEditor.Shell.Traditional.State do
      def set_modal(shell_state, modal) do
        %{shell_state | modal: modal}
      end
    end
    """
    |> check("lib/minga_editor/shell/traditional/state.ex")
    |> refute_issues()
  end
end

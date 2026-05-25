defmodule MingaEditor.Test.UnknownGuiPayloadShell do
  @moduledoc "Test shell that returns an unsupported GUI payload tag."

  @spec compute_layout(map()) :: MingaEditor.Layout.t()
  def compute_layout(%{terminal_viewport: viewport}) do
    %MingaEditor.Layout{
      terminal: {0, 0, viewport.cols, viewport.rows},
      editor_area: {0, 0, viewport.cols, max(viewport.rows - 1, 1)},
      minibuffer: {max(viewport.rows - 1, 0), 0, viewport.cols, 1}
    }
  end

  @spec active_session(term()) :: nil
  def active_session(_shell_state), do: nil

  @spec gui_payload(term()) :: {:unknown, term()}
  def gui_payload(_editor_state), do: {:unknown, :payload}
end

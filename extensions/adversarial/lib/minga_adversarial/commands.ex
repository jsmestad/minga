defmodule MingaAdversarial.Commands do
  @moduledoc """
  Command implementations for the adversarial extension.

  Each command reads the active file from editor state and delegates to the
  Watcher, which owns the analysis lifecycle and the skepticism dial.
  """

  alias Minga.Buffer
  alias MingaAdversarial.Watcher
  alias MingaEditor.Extension.EditorAPI

  @spec analyze(EditorAPI.state()) :: EditorAPI.state()
  def analyze(state) do
    case EditorAPI.active_path(state) do
      nil ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "Adversarial: no current file"
        )

      path ->
        case Watcher.analyze(path, live_content(state)) do
          :off ->
            MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
              state,
              "Adversarial: dial is off (M-x adversarial-cycle-skepticism)"
            )

          :ok ->
            MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
              state,
              "Adversarial: challenging #{Path.basename(path)}…"
            )
        end
    end
  end

  @spec clear(EditorAPI.state()) :: EditorAPI.state()
  def clear(state) do
    case EditorAPI.active_path(state) do
      nil ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "Adversarial: no current file"
        )

      path ->
        Watcher.clear(path)

        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "Adversarial: cleared #{Path.basename(path)}"
        )
    end
  end

  @spec cycle_skepticism(EditorAPI.state()) :: EditorAPI.state()
  def cycle_skepticism(state) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Adversarial skepticism: #{Watcher.cycle_skepticism()}"
    )
  end

  # Live (possibly unsaved) text of the active buffer, or nil to fall back to
  # disk. Analyzing the buffer means findings line up with what's on screen.
  @spec live_content(EditorAPI.state()) :: String.t() | nil
  defp live_content(state) do
    case EditorAPI.active_buffer(state) do
      pid when is_pid(pid) -> safe_content(pid)
      _ -> nil
    end
  end

  @spec safe_content(pid()) :: String.t() | nil
  defp safe_content(pid) do
    Buffer.content(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end

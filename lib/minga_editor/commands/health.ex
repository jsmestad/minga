defmodule MingaEditor.Commands.Health do
  @moduledoc """
  `:checkhealth`, the pages that say why Minga behaves as it does on this machine.

  `:checkhealth terminal` lists what the terminal frontend found out about its terminal (`MingaEditor.Frontend.TerminalHealth`). `:checkhealth` alone, or with a name that has no page, lists the pages that exist.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.Commands.Help
  alias MingaEditor.Frontend.TerminalHealth
  alias MingaEditor.Frontend.TerminalOverrides
  alias MingaEditor.Frontend.TerminalReport
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Frontend, as: FrontendState

  @type state :: EditorState.t()

  @pages [{"terminal", "what this terminal can do, and what Minga uses instead"}]

  command(:checkhealth, "List the health pages", requires_buffer: false)

  command(:checkhealth_terminal, "Show what this terminal can do and what Minga falls back to",
    requires_buffer: false
  )

  @doc "Shows a health page, or the list of pages when `topic` names none."
  @spec execute(state(), :checkhealth | :checkhealth_terminal | {:checkhealth, String.t()}) ::
          state()
  def execute(state, :checkhealth), do: show(state, index_lines(nil))
  def execute(state, :checkhealth_terminal), do: execute(state, {:checkhealth, "terminal"})

  def execute(state, {:checkhealth, "terminal"}) do
    overrides = TerminalOverrides.configured(state.interaction.options_server)
    show(state, TerminalHealth.lines(subject(state.frontend), overrides))
  end

  def execute(state, {:checkhealth, topic}) when is_binary(topic),
    do: show(state, index_lines(topic))

  @doc "Returns what the terminal page reads its facts from, for a frontend."
  @spec subject(FrontendState.t()) :: TerminalHealth.subject()
  def subject(%FrontendState{backend: backend} = frontend),
    do: subject(FrontendState.terminal_report(frontend), backend)

  @spec subject(TerminalReport.t() | nil, FrontendState.backend()) :: TerminalHealth.subject()
  defp subject(%TerminalReport{} = report, _backend), do: report
  defp subject(nil, :tui), do: :no_report
  defp subject(nil, _native_or_headless), do: :not_a_terminal

  @spec index_lines(String.t() | nil) :: [String.t()]
  defp index_lines(unknown) do
    intro =
      case unknown do
        nil -> []
        topic -> ["There is no health page named #{inspect(topic)}.", ""]
      end

    intro ++
      ["Health pages", ""] ++
      Enum.map(@pages, fn {name, about} -> "  :checkhealth #{name}    #{about}" end)
  end

  @spec show(state(), [String.t()]) :: state()
  defp show(state, lines), do: Help.show_in_help_buffer(state, Enum.join(lines, "\n"))
end

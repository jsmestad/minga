defmodule MingaEditor.UI.Picker.ContextArtifactSource do
  @moduledoc """
  Picker source for loading saved agent context artifacts into the prompt.

  Context artifacts are explicit one-off prompt attachments, not hidden session
  memory. Selecting an artifact inserts an `@.minga/context/...` mention into
  the active prompt so the existing file-mention resolver reads the file when
  the user submits.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.ContextArtifact
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Context Artifacts"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{} = ctx) do
    project_root = project_root(ctx)

    project_root
    |> ContextArtifact.list()
    |> Enum.map(&artifact_item(&1, project_root))
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: relative_path}, state) when is_binary(relative_path) do
    mention = "@#{relative_path} "

    AgentAccess.update_agent_ui(state, fn ui ->
      ui
      |> UIState.ensure_prompt_buffer()
      |> UIState.insert_paste(mention)
      |> UIState.set_input_focused(true)
    end)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec artifact_item(String.t(), String.t()) :: Item.t()
  defp artifact_item(path, project_root) do
    relative = Path.relative_to(path, project_root)
    basename = Path.basename(path, ".md")

    %Item{
      id: relative,
      label: basename,
      description: Path.dirname(relative),
      two_line: true
    }
  end

  @spec project_root(Context.t()) :: String.t()
  defp project_root(%Context{picker_ui: %{context: %{project_root: root}}})
       when is_binary(root) do
    root
  end

  defp project_root(_ctx), do: Minga.Project.resolve_root()
end

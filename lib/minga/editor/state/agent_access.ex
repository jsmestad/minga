defmodule Minga.Editor.State.AgentAccess do
  @moduledoc """
  Direct accessors for agent state on EditorState.

  Agent state is split across three structs on EditorState:

  - `agent` (`Editor.State.Agent`) — session lifecycle (PIDs, monitors, status)
    Lives on EditorState directly (global, not per-tab).
  - `agent_ui` (`Agent.UIState`) — full UI state wrapping Panel and View
    Lives in `state.workspace.agent_ui` (per-tab).
  - `agent_ui.panel` (`UIState.Panel`) — prompt editing and chat display
  - `agent_ui.view` (`UIState.View`) — layout, search, preview, toasts

  This module provides read/write functions so callers don't need to know
  the field layout.
  """

  alias Minga.Agent.UIState
  alias Minga.Agent.UIState.Panel
  alias Minga.Agent.UIState.View
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState

  # ── Readers ────────────────────────────────────────────────────────────────

  @doc "Returns the agent session lifecycle state."
  @spec agent(EditorState.t() | map()) :: AgentState.t()
  def agent(%EditorState{agent: a}), do: a
  def agent(%{agent: a}), do: a
  def agent(_), do: %AgentState{}

  @doc "Returns the full agent UI state (wrapping Panel and View)."
  @spec agent_ui(EditorState.t() | map()) :: UIState.t()
  def agent_ui(%EditorState{workspace: %{agent_ui: a}}), do: a
  def agent_ui(%EditorState{workspace: %{agent_ui: a}}), do: a
  def agent_ui(%{agent_ui: a}), do: a
  def agent_ui(_), do: UIState.new()

  @doc "Returns the agent panel state (prompt editing and chat display)."
  @spec panel(EditorState.t() | map()) :: Panel.t()
  def panel(%EditorState{workspace: %{agent_ui: %UIState{panel: p}}}), do: p
  def panel(%EditorState{workspace: %{agent_ui: %UIState{panel: p}}}), do: p
  def panel(%{agent_ui: %UIState{panel: p}}), do: p
  def panel(_), do: Panel.new()

  @doc "Returns the agent view state (layout, search, preview, toasts)."
  @spec view(EditorState.t() | map()) :: View.t()
  def view(%EditorState{workspace: %{agent_ui: %UIState{view: v}}}), do: v
  def view(%EditorState{workspace: %{agent_ui: %UIState{view: v}}}), do: v
  def view(%{agent_ui: %UIState{view: v}}), do: v
  def view(_), do: View.new()

  @doc "Returns the agent session pid, or nil."
  @spec session(EditorState.t() | map()) :: pid() | nil
  def session(state), do: agent(state).session

  @doc "Returns true if the agent panel input is focused."
  @spec input_focused?(EditorState.t() | map()) :: boolean()
  def input_focused?(state), do: panel(state).input_focused

  @doc "Returns the agent UI focus."
  @spec focus(EditorState.t() | map()) :: atom()
  def focus(state), do: view(state).focus

  # ── Writers ────────────────────────────────────────────────────────────────

  @doc "Updates agent session lifecycle state via a transform function."
  @spec update_agent(EditorState.t() | map(), (AgentState.t() -> AgentState.t())) ::
          EditorState.t() | map()
  def update_agent(%EditorState{agent: a} = state, fun) do
    %{state | agent: fun.(a)}
  end

  def update_agent(%{agent: a} = state, fun) do
    %{state | agent: fun.(a)}
  end

  @doc deprecated: "Use update_panel/2 or update_view/2 for targeted sub-struct updates"
  @doc "Updates the full agent UI state. Prefer update_panel/2 or update_view/2."
  @spec update_agent_ui(EditorState.t() | map(), (UIState.t() -> UIState.t())) ::
          EditorState.t() | map()
  def update_agent_ui(%EditorState{workspace: %{agent_ui: a} = ws} = state, fun) do
    %{state | workspace: %{ws | agent_ui: fun.(a)}}
  end

  def update_agent_ui(%EditorState{workspace: %{agent_ui: a} = ws} = state, fun) do
    %{state | workspace: %{ws | agent_ui: fun.(a)}}
  end

  def update_agent_ui(%{agent_ui: a} = state, fun) do
    %{state | agent_ui: fun.(a)}
  end

  @doc "Updates just the panel sub-struct via a transform function."
  @spec update_panel(EditorState.t() | map(), (Panel.t() -> Panel.t())) ::
          EditorState.t() | map()
  def update_panel(%EditorState{workspace: %{agent_ui: %UIState{panel: p} = ui} = ws} = state, fun) do
    %{state | workspace: %{ws | agent_ui: %{ui | panel: fun.(p)}}}
  end

  def update_panel(%EditorState{workspace: %{agent_ui: %UIState{panel: p} = ui} = ws} = state, fun) do
    %{state | workspace: %{ws | agent_ui: %{ui | panel: fun.(p)}}}
  end

  def update_panel(%{agent_ui: %UIState{panel: p} = ui} = state, fun) do
    %{state | agent_ui: %{ui | panel: fun.(p)}}
  end

  @doc "Updates just the view sub-struct via a transform function."
  @spec update_view(EditorState.t() | map(), (View.t() -> View.t())) ::
          EditorState.t() | map()
  def update_view(%EditorState{workspace: %{agent_ui: %UIState{view: v} = ui} = ws} = state, fun) do
    %{state | workspace: %{ws | agent_ui: %{ui | view: fun.(v)}}}
  end

  def update_view(%EditorState{workspace: %{agent_ui: %UIState{view: v} = ui} = ws} = state, fun) do
    %{state | workspace: %{ws | agent_ui: %{ui | view: fun.(v)}}}
  end

  def update_view(%{agent_ui: %UIState{view: v} = ui} = state, fun) do
    %{state | agent_ui: %{ui | view: fun.(v)}}
  end
end

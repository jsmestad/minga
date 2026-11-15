defmodule MingaEditor.Agent.ReviewTarget do
  @moduledoc "Binds read-only Review actions to the exact offered presentation without retaining authority."

  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar

  @enforce_keys [:path, :freshness, :generation, :item_id]
  defstruct @enforce_keys

  @type intent :: :back_to_chat | :review_file
  @type t :: %__MODULE__{
          path: String.t(),
          freshness: :current | :stale,
          generation: non_neg_integer(),
          item_id: String.t()
        }

  @doc "Projects the same current offer at the editor and rendering boundaries."
  @spec capture(EditorState.t() | Context.t()) :: t() | nil
  def capture(%EditorState{} = state) do
    capture(Map.get(state.workspace.windows.map, state.workspace.windows.active), state)
  end

  def capture(%Context{} = ctx) do
    capture(Map.get(ctx.windows.map, ctx.windows.active), ctx)
  end

  @doc "Regenerates and matches an offer before returning its captured path."
  @spec resolve(EditorState.t(), non_neg_integer(), binary(), intent()) ::
          {:ok, t()} | {:error, :target_mismatch}
  def resolve(state, generation, item_id, intent) do
    case capture(state) do
      %__MODULE__{generation: ^generation, item_id: ^item_id} = target ->
        offered_intent(target, intent)

      _other ->
        {:error, :target_mismatch}
    end
  end

  @spec capture(map() | nil, EditorState.t() | Context.t()) :: t() | nil
  defp capture(%{content: {:agent_review, :semantic}} = window, %EditorState{} = state) do
    runtime = state.shell_runtime

    offer(
      window,
      state.workspace.agent_ui.view.preview,
      Runtime.identity(runtime),
      Runtime.review_scope(runtime),
      Runtime.traditional_tab_bar(runtime)
    )
  end

  defp capture(%{content: {:agent_review, :semantic}} = window, %Context{} = ctx) do
    frame = ctx.intent.frame

    offer(
      window,
      ctx.workspace.agent_ui.view.preview,
      frame.shell_identity,
      Runtime.review_scope(frame.shell, frame.shell_state),
      ctx.tab_bar
    )
  end

  defp capture(_window, _context), do: nil

  @spec offer(map() | nil, Preview.t(), term(), Runtime.review_scope() | nil, TabBar.t() | nil) ::
          t() | nil
  defp offer(
         %{content: {:agent_review, :semantic}, id: id, accessibility_generation: generation},
         preview,
         identity,
         {_workspace_id, _session_pid} = scope,
         %TabBar{active_id: tab_id}
       ) do
    case Preview.review_source(preview) do
      {:diff, path, rows_revision, _selection_revision} = source ->
        binding = {:review, 1, identity, scope, tab_id, {id, generation}, source}
        digest = :crypto.hash(:sha256, :erlang.term_to_binary(binding))

        %__MODULE__{
          path: path,
          freshness: preview.freshness,
          generation: rows_revision,
          item_id: "r1." <> Base.url_encode64(digest, padding: false)
        }

      nil ->
        nil
    end
  end

  defp offer(_window, _preview, _identity, _scope, _tab_bar), do: nil

  @spec offered_intent(t(), intent()) :: {:ok, t()} | {:error, :target_mismatch}
  defp offered_intent(%__MODULE__{} = target, :back_to_chat), do: {:ok, target}
  defp offered_intent(%__MODULE__{freshness: :stale} = target, :review_file), do: {:ok, target}
  defp offered_intent(%__MODULE__{}, _intent), do: {:error, :target_mismatch}
end

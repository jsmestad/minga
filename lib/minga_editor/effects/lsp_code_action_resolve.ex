defmodule MingaEditor.Effects.LspCodeActionResolve do
  @moduledoc """
  Typed effect for resolving one deferred LSP code action.

  The effect retains the producing document context while the blocking LSP request runs under the Editor generation's supervised effect scheduler. Application revalidates that context before any edit or command can run.
  """

  @behaviour MingaEditor.Effect

  alias Minga.LSP.Client
  alias Minga.LSP.DocumentContext
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.CodeActionSource

  @resolve_timeout_ms 5_000
  @scheduler_timeout_ms 6_000

  @enforce_keys [:action, :context, :generation]
  defstruct [:action, :context, :generation]

  @type t :: %__MODULE__{
          action: map(),
          context: DocumentContext.t(),
          generation: MingaEditor.State.LSP.workspace_generation()
        }

  @doc "Builds a latest-wins resolve request for one producing client and document."
  @spec request(map(), DocumentContext.t(), MingaEditor.State.LSP.workspace_generation()) ::
          Request.t()
  def request(action, %DocumentContext{} = context, generation)
      when is_map(action) and is_integer(generation) and generation > 0 do
    effect = %__MODULE__{action: action, context: context, generation: generation}

    Request.new(
      effect,
      {:lsp_code_action_resolve, context.client, context.buffer},
      Policy.latest_wins(),
      timeout_ms: @scheduler_timeout_ms
    )
  end

  @impl true
  @spec run(t()) :: {:ok, map()} | {:error, term()}
  def run(%__MODULE__{action: action, context: context}) do
    ref = Client.request(context.client, "codeAction/resolve", action)

    result =
      receive do
        {:lsp_response, ^ref, response} -> response
      after
        @resolve_timeout_ms -> {:error, :timeout}
      end

    case result do
      {:ok, resolved} when is_map(resolved) -> {:ok, resolved}
      {:ok, _invalid} -> {:error, :invalid_resolve_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{
          value: {:completed, resolved},
          request: %{effect: %__MODULE__{context: context, generation: generation}}
        } = outcome
      ) do
    {CodeActionSource.apply_resolved_action(state, resolved, context, generation), outcome}
  end

  def apply(state, %Outcome{value: {:failed, reason}} = outcome) do
    {CodeActionSource.resolve_failed(state, reason), outcome}
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _payload}}) when status in [:completed, :failed], do: true
  def render?(%Outcome{}), do: false
end

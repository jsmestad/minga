defmodule MingaAgent.Test.ModelPickerSession do
  @moduledoc "Isolated model-candidate query endpoint for picker presentation tests."
  use GenServer

  @type candidates :: [MingaAgent.ModelCandidate.t()]

  @spec start_link(candidates()) :: GenServer.on_start()
  def start_link(candidates), do: GenServer.start_link(__MODULE__, candidates)

  @impl true
  @spec init(candidates()) :: {:ok, candidates()}
  def init(candidates), do: {:ok, candidates}

  @impl true
  @spec handle_call(
          :begin_model_discovery | :get_available_models | :inference_route_context,
          GenServer.from(),
          candidates()
        ) ::
          {:reply, :local | {:ok, candidates()} | {:error, :unsupported}, candidates()}
  def handle_call(:begin_model_discovery, _from, candidates), do: {:reply, :local, candidates}

  def handle_call(:inference_route_context, _from, candidates),
    do: {:reply, {:error, :unsupported}, candidates}

  def handle_call(:get_available_models, _from, candidates),
    do: {:reply, {:ok, candidates}, candidates}
end

defmodule Minga.Test.EffectOwner do
  @moduledoc "Minimal generation owner that finalizes scheduler outcomes in topology tests."

  use GenServer

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler

  @typep state :: %{scheduler: EffectScheduler.server(), observer: pid()}

  @doc "Starts and attaches a test owner to the injected generation scheduler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    scheduler = Keyword.fetch!(opts, :effect_scheduler)
    observer = Keyword.fetch!(opts, :observer)
    :ok = EffectScheduler.attach(scheduler, self())
    send(observer, {:effect_owner_started, self(), scheduler})
    {:ok, %{scheduler: scheduler, observer: observer}}
  end

  @impl true
  def handle_info({:effect_lifecycle, %Outcome{} = outcome}, state) do
    send(state.observer, {:owner_lifecycle, self(), outcome})
    {:noreply, state}
  end

  def handle_info({:effect_result, scheduler, %Outcome{} = outcome}, state) do
    send(state.observer, {:owner_result, self(), outcome})
    EffectScheduler.finalize(scheduler, outcome)
    {:noreply, state}
  end
end

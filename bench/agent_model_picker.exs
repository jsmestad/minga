defmodule Minga.Bench.AgentModelPicker.Session do
  @moduledoc false
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(resolver_opts), do: GenServer.start_link(__MODULE__, resolver_opts)

  @impl GenServer
  def init(resolver_opts), do: {:ok, resolver_opts}

  @impl GenServer
  def handle_call(:get_available_models, _from, resolver_opts) do
    {:reply, {:ok, MingaAgent.ModelResolver.candidates(resolver_opts)}, resolver_opts}
  end
end

defmodule Minga.Bench.AgentModelPicker do
  @moduledoc false

  alias MingaAgent.Config
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ProviderPacks.Native
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.UI.Picker.AgentModelSource
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  @warmup_iterations 10
  @default_samples 100

  @spec run() :: :ok
  def run do
    {:ok, _apps} = Application.ensure_all_started(:req_llm)
    samples = sample_count!()
    catalog = LLMDB.models()
    resolver_opts = resolver_opts()
    {:ok, session} = Minga.Bench.AgentModelPicker.Session.start_link(resolver_opts)
    context = context(session)

    {cold_us, cold_candidates} = :timer.tc(fn -> AgentModelSource.candidates(context) end)

    for _ <- 1..@warmup_iterations do
      AgentModelSource.candidates(context)
    end

    warm_us =
      for _ <- 1..samples do
        {elapsed_us, _candidates} = :timer.tc(fn -> AgentModelSource.candidates(context) end)
        elapsed_us
      end

    result = %{
      benchmark: "agent_model_picker_candidates",
      methodology: %{
        cold: "first complete picker candidate build in a fresh optimized BEAM",
        warm: "sequential complete builds in the same process after fixed warmup",
        included: [
          "session GenServer call",
          "exact route resolution over the pinned LLMDB catalog",
          "candidate sorting",
          "picker item formatting"
        ],
        excluded: ["editor rendering", "network I/O", "credential value reads"]
      },
      environment: %{
        mix_env: to_string(Mix.env()),
        elixir: System.version(),
        otp_release: System.otp_release()
      },
      catalog: %{
        size: length(catalog),
        sha256: catalog_fingerprint(catalog),
        picker_candidates: length(cold_candidates)
      },
      cold_us: cold_us,
      warm: %{
        warmup_iterations: @warmup_iterations,
        samples: samples,
        min_us: Enum.min(warm_us),
        mean_us: Float.round(Enum.sum(warm_us) / samples, 2),
        p50_us: percentile(warm_us, 0.50),
        p95_us: percentile(warm_us, 0.95),
        max_us: Enum.max(warm_us)
      }
    }

    IO.puts(JSON.encode!(result))
    GenServer.stop(session)
    :ok
  end

  @spec resolver_opts() :: keyword()
  defp resolver_opts do
    credential_sources =
      Map.new(~w(anthropic openai openrouter google groq mistral deepseek), &{&1, :env})

    [
      config: %Config{},
      credential_snapshot: Snapshot.new(credential_sources, nil, "http://127.0.0.1:11434"),
      backend_spec: Native.spec()
    ]
  end

  @spec context(pid()) :: Context.t()
  defp context(session) do
    %Context{
      buffers: %Buffers{},
      editing: VimState.new(),
      search: %Search{},
      viewport: Viewport.new(80, 24),
      tab_bar: %{},
      agent_session: session,
      picker_ui: %{},
      capabilities: %{},
      theme: Theme.get!(:minga_default)
    }
  end

  @spec sample_count!() :: pos_integer()
  defp sample_count! do
    value = System.get_env("MINGA_BENCH_SAMPLES", Integer.to_string(@default_samples))

    case Integer.parse(value) do
      {samples, ""} when samples > 0 -> samples
      _other -> raise "MINGA_BENCH_SAMPLES must be a positive integer"
    end
  end

  @spec catalog_fingerprint([term()]) :: String.t()
  defp catalog_fingerprint(catalog) do
    catalog
    |> Enum.map(&:erlang.term_to_binary/1)
    |> Enum.sort()
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec percentile([non_neg_integer()], float()) :: non_neg_integer()
  defp percentile(samples, percentile) do
    sorted = Enum.sort(samples)
    index = floor((length(sorted) - 1) * percentile)
    Enum.at(sorted, index)
  end
end

Minga.Bench.AgentModelPicker.run()

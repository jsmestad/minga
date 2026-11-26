defmodule Minga.Test.Storyboard.Registry do
  @moduledoc """
  The storyboard factory's scenario registry: one `Minga.Test.Storyboard.Entry` per scenario id.

  Entries live in one module per journey under `test/support/storyboard/scenarios/`. `test/storyboard/registry_test.exs` keeps the registry and `docs/design/scenarios.toml` in step: every designed id has an entry, and every entry names an id in the inventory.

  ## Reuse (#4036)

  The registry is pure data in, semantic model out:

      session = Minga.Test.Storyboard.Registry.drive("edit.whichkey.leader")
      model = Minga.Test.Storyboard.Session.model(session)
      "edit.whichkey.leader" = Minga.Test.Storyboard.Registry.classify(model)

  `drive/2` starts a headless editor (pass `rendering: :enabled` to also get rendered frames) and presses the entry's key path from the cold start.
  """

  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Scenarios
  alias Minga.Test.Storyboard.Session

  @journeys [
    Scenarios.Start,
    Scenarios.Edit,
    Scenarios.Search,
    Scenarios.Code,
    Scenarios.Git,
    Scenarios.Minga,
    Scenarios.Terminal,
    Scenarios.Files,
    Scenarios.Windows,
    Scenarios.Settings,
    Scenarios.Errors
  ]

  @home "edit.plain"
  @cold_start "start.open_dir.home"

  @doc "Every registry entry, journey by journey."
  @spec entries() :: [Entry.t()]
  def entries, do: Enum.flat_map(@journeys, & &1.entries())

  @doc "Looks up one entry by scenario id."
  @spec fetch(String.t()) :: {:ok, Entry.t()} | :error
  def fetch(id) do
    case Enum.find(entries(), &(&1.id == id)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "Like `fetch/1`, but raises for an id without an entry."
  @spec fetch!(String.t()) :: Entry.t()
  def fetch!(id) do
    case fetch(id) do
      {:ok, entry} -> entry
      :error -> raise ArgumentError, "no storyboard registry entry for #{inspect(id)}"
    end
  end

  @doc "Entries the real editor can be driven to today."
  @spec built() :: [Entry.t()]
  def built, do: Enum.filter(entries(), &Entry.built?/1)

  @doc "Entries whose surface waits on a ticket."
  @spec pending() :: [Entry.t()]
  def pending, do: Enum.reject(entries(), &Entry.built?/1)

  @doc "The id of plain editing, the scenario the flow explorer presses every key from."
  @spec home() :: String.t()
  def home, do: @home

  @doc "The id of the factory's cold start: `minga .` in a project with no saved session."
  @spec cold_start() :: String.t()
  def cold_start, do: @cold_start

  @doc "True for a resting view (`home = true` in the inventory): every way-out check may end on one."
  @spec resting?(String.t() | :unknown) :: boolean()
  def resting?(id) when is_binary(id), do: id in Minga.Test.Storyboard.Inventory.home_ids()
  def resting?(:unknown), do: false

  @doc """
  Starts a headless editor and drives it to the scenario. Raises for a pending entry.

  `opts` go to `Minga.Test.Storyboard.Session.start/1`, merged over the entry's own `start` options.
  """
  @spec drive(String.t() | Entry.t(), keyword()) :: Session.t()
  def drive(id_or_entry, opts \\ [])
  def drive(id, opts) when is_binary(id), do: id |> fetch!() |> drive(opts)

  def drive(%Entry{status: :built} = entry, opts) do
    session = entry.start |> Keyword.merge(opts) |> Session.start()

    case entry.reach do
      "" -> session
      path -> session |> Session.press(path) |> await_recognized(entry) |> Session.settle()
    end
  end

  def drive(%Entry{id: id, status: {:pending, issue, reason}}, _opts) do
    raise ArgumentError, "#{id} is pending ##{issue} (#{reason}) and cannot be driven yet"
  end

  # Some keys finish their work after the key is handled (opening the
  # conversation waits for the model catalog), so wait until the frame is the
  # scenario before anyone looks at it.
  @spec await_recognized(Session.t(), Entry.t()) :: Session.t()
  defp await_recognized(%Session{ctx: ctx} = session, %Entry{} = entry) do
    turn = entry.start |> Keyword.get(:conversation, []) |> Keyword.get(:turn)

    Minga.Test.EditorCase.wait_until(
      ctx,
      fn _state ->
        model = Session.model(session)
        entry.recognize.(model) and seeded_turn_ready?(model, turn)
      end,
      max_attempts: 250,
      interval_ms: 20,
      message: "expected #{entry.id}'s reach keys to land on #{entry.id} with the seeded turn"
    )

    session
  end

  @spec seeded_turn_ready?(Model.t(), :working | :stopped | :idle | nil) :: boolean()
  defp seeded_turn_ready?(%Model{}, nil), do: true

  defp seeded_turn_ready?(
         %Model{ui: %{agent_chat: %{lifecycle: :conversation}}, conversation: %{status: status}},
         turn
       ) do
    case turn do
      :working -> status in [:thinking, :tool_executing]
      :stopped -> status == :stopped
      :idle -> status == :idle
    end
  end

  defp seeded_turn_ready?(%Model{}, _turn), do: false

  @doc """
  Classifies a semantic model as the first built scenario that recognizes it.

  Returns `:unknown` when none does; `Minga.Test.Storyboard.Model.signature/1` describes such a frame for reports.
  """
  @spec classify(Model.t()) :: String.t() | :unknown
  def classify(%Model{} = model) do
    case Enum.find(built(), & &1.recognize.(model)) do
      nil -> :unknown
      entry -> entry.id
    end
  end
end

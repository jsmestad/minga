defmodule Minga.Shell.Board.Persistence do
  @moduledoc """
  Persists Board card layout to disk so cards survive app restarts.

  Saves card metadata (task, model, kind, grid position) to a JSON file
  in the Minga data directory. Live state (workspace snapshots, session
  PIDs, elapsed timers) is NOT persisted; on restart, cards load as :idle.

  The file is written on every card creation/deletion and on editor
  shutdown. It's read once during Board.init.
  """

  alias Minga.Shell.Board.Card
  alias Minga.Shell.Board.State

  @board_file "board.json"

  @doc "Saves the current board layout to disk."
  @spec save(State.t()) :: :ok | {:error, term()}
  def save(%State{} = state) do
    cards =
      state
      |> State.sorted_cards()
      |> Enum.map(fn card ->
        %{
          "id" => card.id,
          "task" => card.task,
          "model" => card.model,
          "kind" => to_string(card.kind),
          "recent_files" => card.recent_files || []
        }
      end)

    data = %{
      "version" => 1,
      "next_id" => state.next_id,
      "focused_card" => state.focused_card,
      "cards" => cards
    }

    path = board_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    json = JSON.encode!(data)
    File.write(path, json)
  rescue
    e -> {:error, e}
  end

  @doc "Loads saved board layout from disk, returns keyword list for Board.init."
  @spec load() :: State.t() | nil
  def load do
    path = board_path()

    case File.read(path) do
      {:ok, content} ->
        case JSON.decode(content) do
          {:ok, data} -> restore_state(data)
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "Deletes the board persistence file."
  @spec clear() :: :ok
  def clear do
    path = board_path()
    File.rm(path)
    :ok
  rescue
    _ -> :ok
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec restore_state(map()) :: State.t()
  defp restore_state(%{"version" => 1, "cards" => cards_data} = data) do
    next_id = Map.get(data, "next_id", 1)
    focused = Map.get(data, "focused_card")

    cards =
      Enum.reduce(cards_data, %{}, fn card_data, acc ->
        id = Map.get(card_data, "id", 0)
        kind = parse_kind(Map.get(card_data, "kind", "agent"))

        card = %Card{
          id: id,
          task: Map.get(card_data, "task", ""),
          model: Map.get(card_data, "model"),
          kind: kind,
          status: :idle,
          session: nil,
          workspace: nil,
          created_at: DateTime.utc_now(),
          recent_files: Map.get(card_data, "recent_files", [])
        }

        Map.put(acc, id, card)
      end)

    %State{
      cards: cards,
      next_id: next_id,
      focused_card: if(Map.has_key?(cards, focused), do: focused, else: nil)
    }
  end

  defp restore_state(_), do: nil

  @spec parse_kind(String.t()) :: :you | :agent
  defp parse_kind("you"), do: :you
  defp parse_kind(_), do: :agent

  @spec board_path() :: String.t()
  defp board_path do
    data_dir =
      case :os.type() do
        {:unix, :darwin} ->
          Path.join(System.get_env("HOME", "~"), "Library/Application Support/minga")

        _ ->
          Path.join(
            System.get_env("XDG_DATA_HOME", Path.join(System.get_env("HOME", "~"), ".local/share")),
            "minga"
          )
      end

    Path.join(data_dir, @board_file)
  end
end

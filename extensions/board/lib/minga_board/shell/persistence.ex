defmodule MingaBoard.Shell.Persistence do
  @moduledoc """
  Persists Board card layout to disk so cards survive app restarts.

  Saves card metadata (task, model, kind, grid position) to a JSON file
  in the Minga data directory. Live state (workspace snapshots, session
  PIDs, elapsed timers) is NOT persisted; on restart, cards load as :idle.

  The file is written on every card creation/deletion and on editor
  shutdown. It's read once during Board.init.
  """

  alias MingaBoard.Shell.Card
  alias MingaBoard.Shell.State

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
      "card_order" => state.card_order,
      "cards" => cards
    }

    path = board_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    json = JSON.encode!(data)

    case File.write(path, json) do
      :ok ->
        :ok

      {:error, reason} = error ->
        log_persistence_warning("save", path, reason)
        error
    end
  rescue
    e ->
      log_persistence_warning("save", board_path(), e)
      {:error, e}
  end

  @doc "Loads saved board layout from disk, returns keyword list for Board.init."
  @spec load() :: State.t() | nil
  def load do
    path = board_path()

    case File.read(path) do
      {:ok, content} ->
        case JSON.decode(content) do
          {:ok, data} -> restore_loaded_state(path, data)
          {:error, reason} -> log_load_failure(path, reason)
        end

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        log_load_failure(path, reason)
    end
  rescue
    e -> log_load_failure(board_path(), e)
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

  @spec restore_loaded_state(String.t(), term()) :: State.t() | nil
  defp restore_loaded_state(path, data) do
    case restore_state(data) do
      {:ok, %State{} = state} -> state
      {:error, reason} -> log_load_failure(path, {:invalid_board_persistence, reason})
    end
  end

  @spec log_load_failure(String.t(), term()) :: nil
  defp log_load_failure(path, reason) do
    log_persistence_warning("load", path, reason)
    nil
  end

  @spec log_persistence_warning(String.t(), String.t(), term()) :: :ok
  defp log_persistence_warning(action, path, reason) do
    Minga.Log.warning(
      :agent,
      "Board persistence #{action} failed for #{path}: #{inspect(reason)}"
    )
  end

  @spec restore_state(term()) :: {:ok, State.t()} | {:error, term()}
  defp restore_state(%{"version" => 1, "cards" => cards_data} = data) when is_list(cards_data) do
    with {:ok, cards, max_id} <- restore_cards(cards_data),
         {:ok, next_id} <- restore_next_id(Map.get(data, "next_id", 1), max_id) do
      focused = Map.get(data, "focused_card")
      card_order = normalize_card_order(Map.get(data, "card_order"), cards)

      {:ok,
       %State{
         cards: cards,
         card_order: card_order,
         next_id: next_id,
         focused_card: if(Map.has_key?(cards, focused), do: focused, else: nil)
       }}
    end
  end

  defp restore_state(_), do: {:error, :invalid_shape}

  @spec restore_cards([term()]) ::
          {:ok, %{pos_integer() => Card.t()}, non_neg_integer()} | {:error, term()}
  defp restore_cards(cards_data) do
    Enum.reduce_while(cards_data, {:ok, %{}, 0}, &restore_card/2)
  end

  @spec restore_card(term(), {:ok, map(), non_neg_integer()}) ::
          {:cont, {:ok, map(), non_neg_integer()}} | {:halt, {:error, term()}}
  defp restore_card(card_data, {:ok, cards, max_id}) when is_map(card_data) do
    with {:ok, id} <- restore_card_id(Map.get(card_data, "id"), cards),
         {:ok, task} <- restore_string(Map.get(card_data, "task", "")),
         {:ok, model} <- restore_optional_string(Map.get(card_data, "model")),
         {:ok, recent_files} <- restore_recent_files(Map.get(card_data, "recent_files", [])) do
      card = %Card{
        id: id,
        task: task,
        model: model,
        kind: parse_kind(Map.get(card_data, "kind", "agent")),
        status: :idle,
        session: nil,
        workspace: nil,
        created_at: DateTime.utc_now(),
        recent_files: recent_files
      }

      {:cont, {:ok, Map.put(cards, id, card), max(max_id, id)}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp restore_card(_card_data, _acc), do: {:halt, {:error, :invalid_card}}

  @spec restore_card_id(term(), map()) :: {:ok, pos_integer()} | {:error, term()}
  defp restore_card_id(id, cards) when is_integer(id) and id > 0 do
    if Map.has_key?(cards, id), do: {:error, {:duplicate_card_id, id}}, else: {:ok, id}
  end

  defp restore_card_id(id, _cards), do: {:error, {:invalid_card_id, id}}

  @spec restore_string(term()) :: {:ok, String.t()} | {:error, term()}
  defp restore_string(value) when is_binary(value), do: {:ok, value}
  defp restore_string(value), do: {:error, {:invalid_string, value}}

  @spec restore_optional_string(term()) :: {:ok, String.t() | nil} | {:error, term()}
  defp restore_optional_string(nil), do: {:ok, nil}
  defp restore_optional_string(value), do: restore_string(value)

  @spec restore_recent_files(term()) :: {:ok, [String.t()]} | {:error, term()}
  defp restore_recent_files(files) when is_list(files) do
    if Enum.all?(files, &is_binary/1),
      do: {:ok, files},
      else: {:error, {:invalid_recent_files, files}}
  end

  defp restore_recent_files(files), do: {:error, {:invalid_recent_files, files}}

  @spec restore_next_id(term(), non_neg_integer()) :: {:ok, pos_integer()} | {:error, term()}
  defp restore_next_id(next_id, max_id) when is_integer(next_id) and next_id > max_id do
    {:ok, next_id}
  end

  defp restore_next_id(next_id, max_id) when is_integer(next_id) and next_id > 0 do
    {:ok, max_id + 1}
  end

  defp restore_next_id(next_id, _max_id), do: {:error, {:invalid_next_id, next_id}}

  @spec normalize_card_order(term(), %{integer() => Card.t()}) :: [integer()]
  defp normalize_card_order(order, cards) when is_list(order) do
    card_ids = Map.keys(cards)
    ordered_ids = order |> Enum.filter(&Map.has_key?(cards, &1)) |> Enum.uniq()
    missing_ids = Enum.sort(card_ids -- ordered_ids)
    ordered_ids ++ missing_ids
  end

  defp normalize_card_order(_order, cards), do: Enum.sort(Map.keys(cards))

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
            System.get_env(
              "XDG_DATA_HOME",
              Path.join(System.get_env("HOME", "~"), ".local/share")
            ),
            "minga"
          )
      end

    Path.join(data_dir, @board_file)
  end
end

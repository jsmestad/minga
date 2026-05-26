defmodule MingaBoard.Shell.PersistenceTest do
  @moduledoc "Tests for Board persistence failure handling."

  # Mutates global HOME and XDG_DATA_HOME while testing platform-specific persistence paths.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MingaBoard.Shell.Persistence
  alias MingaBoard.Shell.State, as: BoardState

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous_xdg = System.get_env("XDG_DATA_HOME")
    previous_home = System.get_env("HOME")
    System.put_env("XDG_DATA_HOME", dir)
    System.put_env("HOME", dir)

    on_exit(fn ->
      restore_env("XDG_DATA_HOME", previous_xdg)
      restore_env("HOME", previous_home)
    end)

    %{data_dir: dir}
  end

  test "load returns nil and logs invalid JSON", %{data_dir: dir} do
    path = board_path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{")

    log = capture_log(fn -> assert Persistence.load() == nil end)

    assert log =~ "Board persistence load failed"
    assert log =~ path
  end

  test "load rejects invalid card ids and logs", %{data_dir: dir} do
    path = board_path(dir)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "next_id" => 1,
        "cards" => [%{"id" => 0, "task" => "Bad", "kind" => "agent"}]
      })
    )

    log = capture_log(fn -> assert Persistence.load() == nil end)

    assert log =~ "Board persistence load failed"
    assert log =~ "invalid_board_persistence"
  end

  test "load rejects malformed persisted card data", %{data_dir: dir} do
    path = board_path(dir)
    File.mkdir_p!(Path.dirname(path))

    malformed_payloads = [
      %{
        "version" => 1,
        "next_id" => 3,
        "cards" => [
          %{"id" => 1, "task" => "First", "kind" => "agent"},
          %{"id" => 1, "task" => "Duplicate", "kind" => "agent"}
        ]
      },
      %{
        "version" => 1,
        "next_id" => 2,
        "cards" => [
          %{"id" => 1, "task" => "Bad files", "kind" => "agent", "recent_files" => ["ok", 42]}
        ]
      },
      %{
        "version" => 1,
        "next_id" => "two",
        "cards" => [%{"id" => 1, "task" => "Bad next id", "kind" => "agent"}]
      }
    ]

    Enum.each(malformed_payloads, fn payload ->
      File.write!(path, JSON.encode!(payload))

      log = capture_log(fn -> assert Persistence.load() == nil end)

      assert log =~ "Board persistence load failed"
      assert log =~ "invalid_board_persistence"
    end)
  end

  test "load preserves cards missing from persisted card_order", %{data_dir: dir} do
    path = board_path(dir)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "next_id" => 3,
        "focused_card" => 1,
        "card_order" => [1],
        "cards" => [
          %{"id" => 1, "task" => "First", "kind" => "agent"},
          %{"id" => 2, "task" => "Second", "kind" => "agent"}
        ]
      })
    )

    assert %BoardState{} = board = Persistence.load()
    assert Enum.map(BoardState.sorted_cards(board), & &1.id) == [1, 2]
  end

  test "load drops stale duplicate card_order entries", %{data_dir: dir} do
    path = board_path(dir)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "next_id" => 1,
        "focused_card" => 2,
        "card_order" => [2, 2, 999],
        "cards" => [
          %{"id" => 1, "task" => "First", "kind" => "agent"},
          %{"id" => 2, "task" => "Second", "kind" => "agent"}
        ]
      })
    )

    assert %BoardState{} = board = Persistence.load()
    assert Enum.map(BoardState.sorted_cards(board), & &1.id) == [2, 1]
    assert board.next_id == 3
  end

  test "save returns an error and logs write setup failures", %{tmp_dir: dir} do
    bad_data_home = Path.join(dir, "not_a_directory")
    File.write!(bad_data_home, "file")
    put_data_home(bad_data_home)

    log =
      capture_log(fn ->
        assert {:error, _reason} = Persistence.save(BoardState.new())
      end)

    assert log =~ "Board persistence save failed"
    assert log =~ bad_data_home
  end

  defp board_path(dir) do
    case :os.type() do
      {:unix, :darwin} ->
        Path.join([dir, "Library", "Application Support", "minga", "board.json"])

      _ ->
        Path.join([dir, "minga", "board.json"])
    end
  end

  defp put_data_home(dir) do
    case :os.type() do
      {:unix, :darwin} -> System.put_env("HOME", dir)
      _ -> System.put_env("XDG_DATA_HOME", dir)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

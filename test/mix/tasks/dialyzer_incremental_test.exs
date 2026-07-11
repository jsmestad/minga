defmodule Mix.Tasks.Dialyzer.IncrementalTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Dialyzer.Incremental

  @moduletag :tmp_dir

  test "cache key changes for every invalidation input" do
    base = ["29.0.3", "1.20.2", "lock", [flags: [:unmatched_returns]]]
    key = apply(Incremental, :cache_key, base)

    for {value, index} <- [
          {"29.0.4", 0},
          {"1.20.3", 1},
          {"changed lock", 2},
          {[flags: [:underspecs]], 3}
        ] do
      changed = List.replace_at(base, index, value)
      refute apply(Incremental, :cache_key, changed) == key
    end
  end

  test "exclusive lock rejects a concurrent writer without removing its lock", %{tmp_dir: dir} do
    lock_path = Path.join(dir, ".lock")
    File.write!(lock_path, "first writer")

    assert_raise Mix.Error, ~r/already locked by another run/, fn ->
      Incremental.with_lock(lock_path, fn -> flunk("second writer acquired lock") end)
    end

    assert File.read!(lock_path) == "first writer"
  end

  test "exclusive lock is removed when the owner raises", %{tmp_dir: dir} do
    lock_path = Path.join(dir, ".lock")

    assert_raise RuntimeError, "interrupted", fn ->
      Incremental.with_lock(lock_path, fn -> raise "interrupted" end)
    end

    refute File.exists?(lock_path)
  end

  test "completed temporary cache atomically replaces the current cache", %{tmp_dir: dir} do
    cache_path = Path.join(dir, "incremental.plt")
    temp_path = Path.join(dir, ".incremental.tmp.plt")
    File.write!(cache_path, "old cache")
    File.write!(temp_path, "completed cache")

    assert :ok = Incremental.promote_cache(temp_path, cache_path)
    assert File.read!(cache_path) == "completed cache"
    refute File.exists?(temp_path)
  end

  test "unchanged native run keeps the current cache", %{tmp_dir: dir} do
    cache_path = Path.join(dir, "incremental.plt")
    File.write!(cache_path, "current cache")

    assert :unchanged = Incremental.promote_cache(Path.join(dir, "missing.tmp"), cache_path)
    assert File.read!(cache_path) == "current cache"
  end

  test "metrics report only values emitted by OTP" do
    assert Incremental.format_metrics("""
           total_modules: 120
           analysed_modules: 7
           reason: incremental_changes
           changed_or_removed_modules: 2
           """) == "Incrementality: changed/removed 2, analyzed 7, total 120"

    assert Incremental.format_metrics("""
           total_modules: 120
           analysed_modules: 120
           reason: new_plt_file
           """) == "Incrementality: analyzed 120, total 120"

    assert Incremental.format_metrics("reason: unavailable\n") == nil
  end
end

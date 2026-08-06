defmodule Mix.Tasks.Dialyzer.IncrementalTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Dialyzer.Incremental

  @moduletag :tmp_dir

  test "cache key changes for every invalidation input" do
    base = ["29.0.5", "1.20.3", "lock", [flags: [:unmatched_returns]]]
    key = apply(Incremental, :cache_key, base)

    for {value, index} <- [
          {"29.0.6", 0},
          {"1.20.4", 1},
          {"changed lock", 2},
          {[flags: [:underspecs]], 3}
        ] do
      changed = List.replace_at(base, index, value)
      refute apply(Incremental, :cache_key, changed) == key
    end
  end

  test "toolchain key changes for OTP and Elixir version changes" do
    key = Incremental.toolchain_key("29.0.5", "1.20.3")

    refute Incremental.toolchain_key("29.0.6", "1.20.3") == key
    refute Incremental.toolchain_key("29.0.5", "1.20.4") == key
  end

  test "uses a compatible cache when the exact cache is absent", %{tmp_dir: dir} do
    cache = cache_paths(dir)
    compatible = Path.join(dir, "#{cache.compatible_prefix}previous.plt")
    File.write!(compatible, "compatible cache")

    assert Incremental.initial_plt(cache) == compatible

    File.write!(cache.plt, "exact cache")
    assert Incremental.initial_plt(cache) == cache.plt
  end

  test "does not use a cache from another toolchain", %{tmp_dir: dir} do
    cache = cache_paths(dir)
    incompatible = Path.join(dir, "incremental-other-toolchain-previous.plt")
    File.write!(incompatible, "incompatible cache")

    assert Incremental.initial_plt(cache) == cache.plt
  end

  test "uses the previous exact cache filename as a migration seed", %{tmp_dir: dir} do
    cache = cache_paths(dir)
    File.write!(cache.legacy_plt, "legacy cache")

    assert Incremental.initial_plt(cache) == cache.legacy_plt
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

  defp cache_paths(dir) do
    %{
      root: dir,
      plt: Path.join(dir, "incremental-compatible-toolchain-current.plt"),
      legacy_plt: Path.join(dir, "incremental-current.plt"),
      lock: Path.join(dir, ".lock"),
      compatible_prefix: "incremental-compatible-toolchain-"
    }
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

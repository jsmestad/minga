defmodule MingaAgent.ModelCatalogTest do
  # async: false — uses capture_log, which captures global Logger output.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MingaAgent.ModelCatalog

  defp start_catalog(loader) do
    supervisor = start_supervised!(Task.Supervisor)

    start_supervised!(
      {ModelCatalog,
       name: nil, task_supervisor: supervisor, loader: loader, loaded?: fn -> false end}
    )
  end

  # Waits through the owner's own request, so the real catalog's global load
  # state cannot short-circuit the probe.
  defp request_load(catalog), do: GenServer.call(catalog, :load)

  test "a catalog load error keeps the public result and logs its cause" do
    catalog = start_catalog(fn -> raise LLMDB.LoadError, reason: :probe_disk_full end)

    log =
      capture_log(fn ->
        assert request_load(catalog) == {:error, :model_catalog_unavailable}
      end)

    assert log =~ "Model catalog load failed"
    assert log =~ ":probe_disk_full"
  end

  test "a crashed load task keeps the public result and logs its exit reason" do
    catalog = start_catalog(fn -> exit(:probe_loader_crashed) end)

    log =
      capture_log(fn ->
        assert request_load(catalog) == {:error, :model_catalog_unavailable}
      end)

    assert log =~ "Model catalog load crashed"
    assert log =~ ":probe_loader_crashed"
  end
end

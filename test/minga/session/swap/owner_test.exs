defmodule Minga.Session.Swap.OwnerTest do
  @moduledoc """
  A swap file is owned by one run of the editor: its OS process id plus the start time the OS reports for that process. A process id alone is reused, so it never decides.
  """

  use ExUnit.Case, async: true

  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery

  @moduletag :tmp_dir

  @before_reboot "Thu Jan  1 00:00:00 1970"
  @neighbour_started "Tue Nov 24 20:27:02 2026"

  # No test here may spawn `ps`: every decision about another process goes through a stand-in.
  defp never_asked(_pid), do: flunk("this decision needs no OS call")

  defp owner(os_pid, run_started), do: %{os_pid: os_pid, run_started: run_started}

  describe "owner_alive?/2 for this VM's process id" do
    test "a swap that carries this run's start time is this run's, with no OS call" do
      %{os_pid: pid, started: started} = Swap.this_run()
      assert Swap.owner_alive?(owner(pid, started), &never_asked/1)
    end

    test "an earlier run that had this process id is gone" do
      refute Swap.owner_alive?(owner(Swap.os_pid(), @before_reboot), &never_asked/1)
    end

    test "a swap from before the start time was recorded cannot be this run's" do
      refute Swap.owner_alive?(owner(Swap.os_pid(), nil), &never_asked/1)
    end
  end

  describe "owner_alive?/2 for another process id" do
    @other 4242

    test "a second live editor keeps its swap: the process has exactly the recorded start" do
      assert Swap.owner_alive?(owner(@other, @neighbour_started), fn @other ->
               {:ok, @neighbour_started}
             end)
    end

    test "a process that got the id later is a stranger, so the swap is recoverable" do
      refute Swap.owner_alive?(owner(@other, @neighbour_started), fn @other ->
               {:ok, "Tue Nov 24 20:27:03 2026"}
             end)
    end

    test "a process that is gone, or a zombie, owns nothing" do
      refute Swap.owner_alive?(owner(@other, @neighbour_started), fn @other -> :error end)
    end

    test "a swap without a recorded start is kept while any process has its id" do
      assert Swap.owner_alive?(owner(@other, nil), fn @other -> {:ok, @neighbour_started} end)
      refute Swap.owner_alive?(owner(@other, nil), fn @other -> :error end)
    end

    test "a process id that cannot exist owns nothing" do
      refute Swap.owner_alive?(owner(0, @neighbour_started), &never_asked/1)
      refute Swap.owner_alive?(owner(-1, nil), &never_asked/1)
    end
  end

  describe "the swap file records its owner" do
    test "a swap this run writes carries this run's identity", %{tmp_dir: dir} do
      path = Path.join(dir, "notes.txt")
      {:ok, prepared} = Swap.prepare(path, "unsaved", swap_dir: dir)
      :ok = Swap.publish(prepared)

      assert {:ok, meta, "unsaved"} = Swap.read(Swap.swap_path(path, swap_dir: dir))
      assert %{os_pid: meta.os_pid, started: meta.run_started} == Swap.this_run()
      assert Swap.owner_alive?(meta, &never_asked/1)
    end

    test "a swap from before the field existed still reads, without a start time", %{tmp_dir: dir} do
      header = "path=/tmp/old.txt\nos_pid=4242\nmtime=1711234567"
      old = <<"MINGA_SWAP_V1\n", byte_size(header)::32-big, header::binary, "old text">>
      swap_path = Path.join(dir, "old.4242.swap")
      File.write!(swap_path, old)

      assert {:ok, %{os_pid: 4242, run_started: nil, path: "/tmp/old.txt"}, "old text"} =
               Swap.read(swap_path)
    end
  end

  describe "a scan with the real owner rule" do
    setup %{tmp_dir: dir} do
      swap_dir = Path.join(dir, "swap")
      path_of = fn name -> Path.join(dir, name) end

      for name <- ["mine.txt", "reused.txt", "neighbour.txt", "stranger.txt"],
          do: File.write!(path_of.(name), "saved")

      %{swap_dir: swap_dir, path_of: path_of}
    end

    test "offers the text of dead runs and leaves live runs alone", ctx do
      # This run's own swap, as a buffer of this VM writes it.
      write(ctx, "mine.txt", [])
      # A run that crashed before a reboot and had the process id this VM has now.
      write(ctx, "reused.txt", run_started: @before_reboot)
      # A second live editor on the same machine.
      write(ctx, "neighbour.txt", os_pid: 5151, run_started: @neighbour_started)
      # A crashed run whose process id now belongs to some other program.
      write(ctx, "stranger.txt", os_pid: 6161, run_started: @neighbour_started)

      start_time = fn
        5151 -> {:ok, @neighbour_started}
        6161 -> {:ok, "Wed Nov 25 09:00:00 2026"}
      end

      recoverable =
        [swap_dir: ctx.swap_dir, owner_alive?: &Swap.owner_alive?(&1, start_time)]
        |> Recovery.scan()
        |> Enum.map(&Path.basename(&1.path))
        |> Enum.sort()

      assert recoverable == ["reused.txt", "stranger.txt"]

      # Nothing of a live run was touched.
      assert File.exists?(Swap.swap_path(ctx.path_of.("mine.txt"), swap_dir: ctx.swap_dir))

      assert File.exists?(
               Swap.swap_path(ctx.path_of.("neighbour.txt"), swap_dir: ctx.swap_dir, os_pid: 5151)
             )
    end
  end

  defp write(ctx, name, opts) do
    {:ok, prepared} =
      Swap.prepare(ctx.path_of.(name), "unsaved #{name}", [swap_dir: ctx.swap_dir] ++ opts)

    :ok = Swap.publish(prepared)
  end
end

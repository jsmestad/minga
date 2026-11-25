defmodule Minga.Session.Swap.OwnerTest do
  @moduledoc """
  A swap file is owned by one run of the editor: its OS process id plus the moment its VM started. A process id alone is reused, so it never decides.
  """

  use ExUnit.Case, async: true

  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery

  @moduletag :tmp_dir

  # No test here may spawn `ps`: every decision about another process goes through a stand-in.
  defp never_probed(_pid), do: flunk("this decision needs no OS call")

  defp owner(os_pid, run_started), do: %{os_pid: os_pid, run_started: run_started}

  describe "owner_alive?/2 for this VM's process id" do
    test "a swap that carries this VM's start time is this run's, with no OS call" do
      assert Swap.owner_alive?(owner(Swap.os_pid(), Swap.run_started()), &never_probed/1)
    end

    test "an earlier run that had this process id is gone" do
      before_reboot = Swap.run_started() - 3_600
      refute Swap.owner_alive?(owner(Swap.os_pid(), before_reboot), &never_probed/1)
    end

    test "a swap from before the start time was recorded cannot be this run's" do
      refute Swap.owner_alive?(owner(Swap.os_pid(), nil), &never_probed/1)
    end
  end

  describe "owner_alive?/2 for another process id" do
    @other 4242
    @recorded 1_800_000_000

    test "a second live editor keeps its swap: the process started when the swap says" do
      for drift <- [-5, -1, 0, 1, 5] do
        assert Swap.owner_alive?(owner(@other, @recorded), fn @other ->
                 {:running, @recorded + drift}
               end)
      end
    end

    test "a process that got the id later is a stranger, so the swap is recoverable" do
      for started <- [@recorded + 6, @recorded - 6, @recorded + 86_400] do
        refute Swap.owner_alive?(owner(@other, @recorded), fn @other -> {:running, started} end)
      end
    end

    test "a process that is gone, or a zombie, owns nothing" do
      refute Swap.owner_alive?(owner(@other, @recorded), fn @other -> :gone end)
    end

    test "when either moment is unknown, a running process keeps the swap" do
      assert Swap.owner_alive?(owner(@other, nil), fn @other -> {:running, @recorded} end)
      assert Swap.owner_alive?(owner(@other, @recorded), fn @other -> {:running, nil} end)
      refute Swap.owner_alive?(owner(@other, nil), fn @other -> :gone end)
    end
  end

  describe "parse_process_state/2" do
    @now 1_800_000_000

    test "reads the elapsed time in every form ps prints" do
      assert Swap.parse_process_state("Ss   00:00\n", @now) == {:running, @now}
      assert Swap.parse_process_state("S    01:05\n", @now) == {:running, @now - 65}
      assert Swap.parse_process_state("R+   02:03:04\n", @now) == {:running, @now - 7_384}

      assert Swap.parse_process_state("Ss   27-09:18:53\n", @now) ==
               {:running, @now - (27 * 86_400 + 9 * 3_600 + 18 * 60 + 53)}
    end

    test "a zombie has exited" do
      assert Swap.parse_process_state("Z    00:10\n", @now) == :gone
      assert Swap.parse_process_state("Z+   1-00:00:10\n", @now) == :gone
    end

    test "no line means no process" do
      assert Swap.parse_process_state("", @now) == :gone
      assert Swap.parse_process_state("\n", @now) == :gone
    end

    test "an elapsed time it cannot read leaves the start unknown" do
      assert Swap.parse_process_state("S    soon\n", @now) == {:running, nil}
      assert Swap.parse_process_state("S\n", @now) == {:running, nil}
    end
  end

  describe "the swap file records its owner" do
    test "a swap this run writes carries this VM's start time", %{tmp_dir: dir} do
      path = Path.join(dir, "notes.txt")
      {:ok, prepared} = Swap.prepare(path, "unsaved", swap_dir: dir)
      :ok = Swap.publish(prepared)

      assert {:ok, meta, "unsaved"} = Swap.read(Swap.swap_path(path, swap_dir: dir))
      assert meta.os_pid == Swap.os_pid()
      assert meta.run_started == Swap.run_started()
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
      file = fn name -> Path.join(dir, name) end

      for name <- ["mine.txt", "reused.txt", "neighbour.txt", "stranger.txt"],
          do: File.write!(file.(name), "saved")

      %{swap_dir: swap_dir, path_of: file}
    end

    test "offers the text of dead runs and leaves live runs alone", ctx do
      neighbour_started = 1_800_000_000

      # This run's own swap, as a buffer of this VM writes it.
      write(ctx, "mine.txt", [])
      # A run that crashed before a reboot and had the process id this VM has now.
      write(ctx, "reused.txt", run_started: Swap.run_started() - 7_200)
      # A second live editor on the same machine.
      write(ctx, "neighbour.txt", os_pid: 5151, run_started: neighbour_started)
      # A crashed run whose process id now belongs to some other program.
      write(ctx, "stranger.txt", os_pid: 6161, run_started: neighbour_started)

      probe = fn
        5151 -> {:running, neighbour_started + 1}
        6161 -> {:running, neighbour_started + 90_000}
      end

      recoverable =
        [swap_dir: ctx.swap_dir, owner_alive?: &Swap.owner_alive?(&1, probe)]
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

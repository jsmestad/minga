defmodule MingaEditor.Frontend.TtyDetectionTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Manager

  describe "tty_path_for/1" do
    test "long-form macOS name produces /dev/ttys* path" do
      # "ttys008" → "/dev/ttys008" (the file exists on macOS)
      # We can't guarantee the exact device exists in CI, but we can
      # verify the path construction logic: if /dev/ttys008 exists,
      # use it directly; otherwise fall back to /dev/ttyttys008.
      result = Manager.tty_path_for("ttys008")

      # On macOS where /dev/ttys008 exists, we get the direct path.
      # On Linux CI where it doesn't, we get the fallback.
      assert result in ["/dev/ttys008", "/dev/ttyttys008"]

      # The critical invariant: if the direct path exists, use it
      if File.exists?("/dev/ttys008") do
        assert result == "/dev/ttys008"
      end
    end

    test "short-form macOS name prepends tty" do
      # "s003" → /dev/s003 doesn't exist → fallback to "/dev/ttys003"
      result = Manager.tty_path_for("s003")
      assert result == "/dev/ttys003"
    end

    test "Linux pts path produces /dev/pts/*" do
      # "pts/3" → "/dev/pts/3" exists on Linux
      result = Manager.tty_path_for("pts/3")

      if File.exists?("/dev/pts/3") do
        assert result == "/dev/pts/3"
      else
        assert result == "/dev/ttypts/3"
      end
    end

    test "direct path is preferred when the device file exists" do
      # Use /dev/tty which exists on all Unix systems
      # Simulate: if ps returned "tty", we'd check /dev/tty first
      assert Manager.tty_path_for("tty") == "/dev/tty"
    end

    test "falls back to /dev/tty{name} when direct path missing" do
      # A name that definitely won't have a matching /dev/ entry
      assert Manager.tty_path_for("z999") == "/dev/ttyz999"
    end
  end
end

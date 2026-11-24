defmodule MingaAgent.Notifier.OSAdapter.LinuxTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Notifier.OSAdapter.Linux

  @found &__MODULE__.notify_send_on_path/1
  @missing &__MODULE__.nothing_on_path/1

  @spec notify_send_on_path(String.t()) :: String.t() | nil
  def notify_send_on_path("notify-send"), do: "/usr/bin/notify-send"
  def notify_send_on_path(_name), do: nil

  @spec nothing_on_path(String.t()) :: nil
  def nothing_on_path(_name), do: nil

  test "a Wayland or X11 session runs notify-send attributed to Minga, with the text as separate arguments" do
    for environment <- [%{"WAYLAND_DISPLAY" => "wayland-1"}, %{"DISPLAY" => ":0"}] do
      assert Linux.command(
               "Minga: Approval Needed",
               "Review the tool request in Minga.",
               environment,
               @found
             ) ==
               {:run, "/usr/bin/notify-send",
                [
                  "--app-name=Minga",
                  "--icon=minga",
                  "--hint=string:desktop-entry:minga",
                  "Minga: Approval Needed",
                  "Review the tool request in Minga."
                ]}
    end
  end

  test "without a graphical session nothing runs, even when notify-send is installed" do
    for environment <- [
          %{},
          %{"WAYLAND_DISPLAY" => "", "DISPLAY" => ""},
          %{"SSH_CONNECTION" => "10.0.0.1 22"}
        ] do
      assert {:skip, reason} = Linux.command("Title", "Body", environment, @found)
      assert reason =~ "no graphical session"
    end
  end

  test "a graphical session without notify-send names the package to install" do
    assert {:skip, reason} =
             Linux.command("Title", "Body", %{"WAYLAND_DISPLAY" => "wayland-1"}, @missing)

    assert reason =~ "libnotify"
  end
end

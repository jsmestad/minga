defmodule MingaEditor.Shell.Traditional.NoticeTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.Notice

  test "publish is latest-wins with monotonic identities" do
    first = Notice.publish(%Notice{}, "first")
    timer = make_ref()
    first = Notice.record_timer(first, first.id, timer)
    second = Notice.publish(first, "second")

    assert %Notice{id: 1, message: "first", timer: ^timer} = first
    assert %Notice{id: 2, message: "second", timer: nil} = second
  end

  test "timer recording and timeout reject stale identities" do
    notice = Notice.publish(%Notice{}, "current")
    stale_timer = make_ref()
    assert Notice.record_timer(notice, 0, stale_timer) == notice
    assert Notice.timeout(notice, 0) == notice

    timer = make_ref()
    notice = Notice.record_timer(notice, notice.id, timer)
    assert %Notice{timer: ^timer} = notice
    assert %Notice{id: 1, message: nil, timer: nil} = Notice.timeout(notice, notice.id)
  end

  test "acknowledge and dismiss clear content but retain identity" do
    notice = Notice.publish(%Notice{}, "current")
    assert %Notice{id: 1, message: nil} = Notice.acknowledge(notice)
    assert %Notice{id: 1, message: nil} = Notice.dismiss(notice)
  end
end

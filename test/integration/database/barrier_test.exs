defmodule PumbleAutomation.BarrierTest do
  @moduledoc """
  The ready/go latch itself. No database: a late racer fails rather than
  proceeding, and both sides of a two-process race start after the release.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Barrier

  test "race starts both functions only after both are ready" do
    parent = self()

    [first, second] =
      Barrier.race([
        fn ->
          send(parent, {:ran, 1, System.monotonic_time()})
          :one
        end,
        fn ->
          send(parent, {:ran, 2, System.monotonic_time()})
          :two
        end
      ])

    assert first == :one
    assert second == :two

    times =
      Enum.map(1..2, fn _index ->
        receive do
          {:ran, _id, time} -> time
        after
          1_000 -> flunk("racer never ran")
        end
      end)

    assert abs(hd(times) - List.last(times)) < System.convert_time_unit(1, :second, :native)
  end

  test "release fails when a racer never checks in" do
    assert_raise ExUnit.AssertionError, fn ->
      Barrier.release(1, 20)
    end
  end
end

defmodule PumbleAutomation.Workflows.ScheduleCalculatorTest do
  @moduledoc """
  Next UTC instants for once/interval/daily/weekly clocks. DST gap and overlap
  policy is Section 23: first valid instant after a spring gap; earlier
  occurrence of a fall overlap. No clock is read.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Definition.ScheduleConfig
  alias PumbleAutomation.Workflows.Node.Config
  alias PumbleAutomation.Workflows.ScheduleCalculator

  describe "once" do
    test "a future instant is returned in UTC" do
      reference = utc("2026-08-01T00:00:00Z")

      assert_next(
        %{schedule_type: :once, run_at: "2026-09-01T09:00:00Z"},
        reference,
        utc("2026-09-01T09:00:00Z")
      )
    end

    test "an offset instant is stored as UTC" do
      reference = utc("2026-08-01T00:00:00Z")

      assert_next(
        %{schedule_type: :once, run_at: "2026-09-01T11:00:00+02:00"},
        reference,
        utc("2026-09-01T09:00:00Z")
      )
    end

    test "a naive instant is interpreted in the schedule timezone" do
      reference = utc("2026-08-01T00:00:00Z")

      assert_next(
        %{
          schedule_type: :once,
          run_at: "2026-09-01T09:00:00",
          timezone: "Europe/Belgrade"
        },
        reference,
        utc("2026-09-01T07:00:00Z")
      )
    end

    test "an instant at or before the reference is terminal" do
      run_at = "2026-09-01T09:00:00Z"

      assert {:ok, :terminal} =
               next(%{schedule_type: :once, run_at: run_at}, utc("2026-09-01T09:00:00Z"))

      assert {:ok, :terminal} =
               next(%{schedule_type: :once, run_at: run_at}, utc("2026-09-02T00:00:00Z"))
    end

    test "a leap-day instant is accepted" do
      assert_next(
        %{schedule_type: :once, run_at: "2028-02-29T12:00:00Z"},
        utc("2028-02-28T00:00:00Z"),
        utc("2028-02-29T12:00:00Z")
      )
    end
  end

  describe "every_minutes and every_hours" do
    test "the next minute grid is the prior scheduled instant plus the interval" do
      scheduled = utc("2026-01-01T00:00:00Z")

      assert_next(
        %{schedule_type: :every_minutes, interval: 15},
        scheduled,
        utc("2026-01-01T00:15:00Z")
      )
    end

    test "the next hour grid is the prior scheduled instant plus the interval" do
      scheduled = utc("2026-03-01T10:00:00Z")

      assert_next(
        %{schedule_type: :every_hours, interval: 6},
        scheduled,
        utc("2026-03-01T16:00:00Z")
      )
    end

    test "repeating from each scheduled instant does not drift" do
      config = %{schedule_type: :every_minutes, interval: 15}
      t0 = utc("2026-01-01T00:00:00Z")
      t1 = utc("2026-01-01T00:15:00Z")
      t2 = utc("2026-01-01T00:30:00Z")
      t3 = utc("2026-01-01T00:45:00Z")

      assert_next(config, t0, t1)
      assert_next(config, t1, t2)
      assert_next(config, t2, t3)
    end

    test "a late completion is not the interval base" do
      scheduled = utc("2026-01-01T00:15:00Z")
      completion = DateTime.add(scheduled, 5, :second)
      config = %{schedule_type: :every_minutes, interval: 15}

      assert_next(config, scheduled, utc("2026-01-01T00:30:00Z"))

      assert {:ok, from_completion} = next(config, completion)
      refute DateTime.compare(from_completion, utc("2026-01-01T00:30:00Z")) == :eq
    end

    test "the minimum interval is one unit" do
      reference = utc("2026-01-01T00:00:00Z")

      assert_next(
        %{schedule_type: :every_minutes, interval: 1},
        reference,
        utc("2026-01-01T00:01:00Z")
      )

      assert {:error, %Error{class: :validation, code: :interval_too_small}} =
               next(%{schedule_type: :every_minutes, interval: 0}, reference)

      assert {:error, %Error{class: :validation, code: :interval_too_small}} =
               next(%{schedule_type: :every_hours, interval: 0}, reference)
    end

    test "a multi-year minute gap is reduced arithmetically to one due slot" do
      config = %{schedule_type: :every_minutes, interval: 1, timezone: "Etc/UTC"}
      first = utc("2020-01-01T00:00:00Z")
      now = utc("2026-08-24T12:34:56Z")

      assert {:ok, latest} = ScheduleCalculator.latest_due(config, first, now)
      assert latest.occurrence == utc("2026-08-24T12:34:00Z")
      assert latest.next_run_at == utc("2026-08-24T12:35:00Z")
      assert latest.skipped == DateTime.diff(latest.occurrence, first, :minute)
    end
  end

  describe "daily" do
    test "the next local time of day after the reference" do
      assert_next(
        %{schedule_type: :daily, time_of_day: "09:00", timezone: "Etc/UTC"},
        utc("2026-06-15T08:00:00Z"),
        utc("2026-06-15T09:00:00Z")
      )
    end

    test "today's occurrence that has already passed yields tomorrow" do
      assert_next(
        %{schedule_type: :daily, time_of_day: "09:00", timezone: "Etc/UTC"},
        utc("2026-06-15T09:00:00Z"),
        utc("2026-06-16T09:00:00Z")
      )
    end

    test "a month boundary is crossed in local dates, not by adding 24 hours" do
      assert_next(
        %{schedule_type: :daily, time_of_day: "09:00", timezone: "Etc/UTC"},
        utc("2026-01-31T09:00:00Z"),
        utc("2026-02-01T09:00:00Z")
      )
    end

    test "a year boundary is crossed in local dates" do
      assert_next(
        %{schedule_type: :daily, time_of_day: "09:00", timezone: "Etc/UTC"},
        utc("2026-12-31T09:00:00Z"),
        utc("2027-01-01T09:00:00Z")
      )
    end

    test "a leap day is a valid daily occurrence" do
      assert_next(
        %{schedule_type: :daily, time_of_day: "12:00", timezone: "Etc/UTC"},
        utc("2028-02-28T12:00:00Z"),
        utc("2028-02-29T12:00:00Z")
      )
    end

    test "a non-leap February 28 yields March 1" do
      assert_next(
        %{schedule_type: :daily, time_of_day: "12:00", timezone: "Etc/UTC"},
        utc("2027-02-28T12:00:00Z"),
        utc("2027-03-01T12:00:00Z")
      )
    end

    test "a decade-long gap inspects only the current local calendar window" do
      config = %{schedule_type: :daily, time_of_day: "09:00", timezone: "Europe/Belgrade"}
      first = utc("2016-01-01T08:00:00Z")
      now = utc("2026-08-24T12:00:00Z")

      assert {:ok, latest} = ScheduleCalculator.latest_due(config, first, now)
      assert latest.occurrence == utc("2026-08-24T07:00:00Z")
      assert latest.next_run_at == utc("2026-08-25T07:00:00Z")
      assert latest.skipped == Date.diff(~D[2026-08-24], ~D[2016-01-01])
    end
  end

  describe "weekly" do
    test "the next selected weekday at local time" do
      # 2026-06-15 is a Monday.
      assert_next(
        %{
          schedule_type: :weekly,
          time_of_day: "09:00",
          weekdays: ["wednesday"],
          timezone: "Etc/UTC"
        },
        utc("2026-06-15T08:00:00Z"),
        utc("2026-06-17T09:00:00Z")
      )
    end

    test "the next week is used when today's occurrence has passed" do
      assert_next(
        %{
          schedule_type: :weekly,
          time_of_day: "09:00",
          weekdays: ["monday"],
          timezone: "Etc/UTC"
        },
        utc("2026-06-15T09:00:00Z"),
        utc("2026-06-22T09:00:00Z")
      )
    end

    test "several weekdays pick the nearest later one" do
      assert_next(
        %{
          schedule_type: :weekly,
          time_of_day: "09:00",
          weekdays: ["monday", "friday"],
          timezone: "Etc/UTC"
        },
        utc("2026-06-16T10:00:00Z"),
        utc("2026-06-19T09:00:00Z")
      )
    end

    test "a stale multi-day clock finds the latest due weekday without walking every week" do
      config = %{
        schedule_type: :weekly,
        time_of_day: "09:00",
        weekdays: ["monday", "wednesday", "friday"],
        timezone: "Europe/Belgrade"
      }

      first = utc("2020-01-06T08:00:00Z")
      now = utc("2026-08-24T12:00:00Z")

      assert {:ok, latest} = ScheduleCalculator.latest_due(config, first, now)
      assert latest.occurrence == utc("2026-08-24T07:00:00Z")
      assert latest.next_run_at == utc("2026-08-26T07:00:00Z")
      assert latest.skipped == 1_038
    end

    test "before today's local time keeps the previous selected weekday due" do
      config = %{
        schedule_type: :weekly,
        time_of_day: "09:00",
        weekdays: ["monday", "wednesday", "friday"],
        timezone: "Europe/Belgrade"
      }

      first = utc("2026-08-17T07:00:00Z")
      before_friday = utc("2026-08-21T06:59:59Z")

      assert {:ok, latest} = ScheduleCalculator.latest_due(config, first, before_friday)
      assert latest.occurrence == utc("2026-08-19T07:00:00Z")
      assert latest.next_run_at == utc("2026-08-21T07:00:00Z")
      assert latest.skipped == 1
    end

    test "an occurrence exactly at now is due and advances to the next selected weekday" do
      config = %{
        schedule_type: :weekly,
        time_of_day: "09:00",
        weekdays: ["monday", "wednesday", "friday"],
        timezone: "Europe/Belgrade"
      }

      first = utc("2026-08-17T07:00:00Z")
      friday = utc("2026-08-21T07:00:00Z")

      assert {:ok, latest} = ScheduleCalculator.latest_due(config, first, friday)
      assert latest.occurrence == friday
      assert latest.next_run_at == utc("2026-08-24T07:00:00Z")
      assert latest.skipped == 2
    end

    test "an empty weekday list is a validation error" do
      assert {:error, %Error{class: :validation, code: :invalid_schedule_config}} =
               next(
                 %{
                   schedule_type: :weekly,
                   time_of_day: "09:00",
                   weekdays: [],
                   timezone: "Etc/UTC"
                 },
                 utc("2026-01-01T00:00:00Z")
               )
    end

    test "an unknown weekday name is a validation error" do
      assert {:error, %Error{class: :validation, code: :invalid_schedule_config}} =
               next(
                 %{
                   schedule_type: :weekly,
                   time_of_day: "09:00",
                   weekdays: ["funday"],
                   timezone: "Etc/UTC"
                 },
                 utc("2026-01-01T00:00:00Z")
               )
    end
  end

  describe "DST spring gap" do
    test "America/New_York uses the first valid instant after 02:30 on 2026-03-08" do
      # 02:30 does not exist; first valid is 03:00 EDT = 07:00 UTC.
      assert_next(
        %{schedule_type: :daily, time_of_day: "02:30", timezone: "America/New_York"},
        utc("2026-03-07T07:30:00Z"),
        utc("2026-03-08T07:00:00Z")
      )
    end

    test "Europe/Belgrade uses the first valid instant after 02:30 on 2026-03-29" do
      # 02:30 does not exist; first valid is 03:00 CEST = 01:00 UTC.
      assert_next(
        %{schedule_type: :daily, time_of_day: "02:30", timezone: "Europe/Belgrade"},
        utc("2026-03-28T01:30:00Z"),
        utc("2026-03-29T01:00:00Z")
      )
    end

    test "Australia/Sydney uses the first valid instant after 02:30 on 2026-10-04" do
      # Previous 02:30 AEST is 2026-10-02 16:30 UTC. 02:30 on 2026-10-04 does
      # not exist; first valid is 03:00 AEDT = 2026-10-03 16:00 UTC.
      assert_next(
        %{schedule_type: :daily, time_of_day: "02:30", timezone: "Australia/Sydney"},
        utc("2026-10-02T16:30:00Z"),
        utc("2026-10-03T16:00:00Z")
      )
    end

    test "latest due includes the shifted gap occurrence at its exact UTC boundary" do
      config = %{
        schedule_type: :daily,
        time_of_day: "02:30",
        timezone: "America/New_York"
      }

      first = utc("2026-03-07T07:30:00Z")
      gap_occurrence = utc("2026-03-08T07:00:00Z")

      assert {:ok, latest} = ScheduleCalculator.latest_due(config, first, gap_occurrence)
      assert latest.occurrence == gap_occurrence
      assert latest.next_run_at == utc("2026-03-09T06:30:00Z")
      assert latest.skipped == 1
    end
  end

  describe "DST fall overlap" do
    test "America/New_York uses the earlier 01:30 on 2026-11-01" do
      # Earlier 01:30 is EDT (UTC-4) = 05:30 UTC.
      assert_next(
        %{schedule_type: :daily, time_of_day: "01:30", timezone: "America/New_York"},
        utc("2026-11-01T04:00:00Z"),
        utc("2026-11-01T05:30:00Z")
      )
    end

    test "Europe/Belgrade uses the earlier 02:30 on 2026-10-25" do
      # Earlier 02:30 is CEST (UTC+2) = 00:30 UTC.
      assert_next(
        %{schedule_type: :daily, time_of_day: "02:30", timezone: "Europe/Belgrade"},
        utc("2026-10-24T00:30:00Z"),
        utc("2026-10-25T00:30:00Z")
      )
    end

    test "Australia/Sydney uses the earlier 02:30 on 2026-04-05" do
      # Earlier 02:30 is AEDT (UTC+11) = 2026-04-04 15:30 UTC.
      assert_next(
        %{schedule_type: :daily, time_of_day: "02:30", timezone: "Australia/Sydney"},
        utc("2026-04-04T14:00:00Z"),
        utc("2026-04-04T15:30:00Z")
      )
    end

    test "latest due keeps one earlier overlap occurrence after both UTC instants pass" do
      config = %{
        schedule_type: :daily,
        time_of_day: "01:30",
        timezone: "America/New_York"
      }

      first = utc("2026-10-31T05:30:00Z")
      after_both_overlap_instants = utc("2026-11-01T06:31:00Z")

      assert {:ok, latest} =
               ScheduleCalculator.latest_due(config, first, after_both_overlap_instants)

      assert latest.occurrence == utc("2026-11-01T05:30:00Z")
      assert latest.next_run_at == utc("2026-11-02T06:30:00Z")
      assert latest.skipped == 1
    end
  end

  describe "horizon and refusals" do
    test "a next instant exactly 365 days later is accepted" do
      reference = utc("2026-01-01T00:00:00Z")
      horizon = DateTime.add(reference, ScheduleCalculator.max_horizon_seconds(), :second)

      assert_next(
        %{schedule_type: :once, run_at: DateTime.to_iso8601(horizon)},
        reference,
        horizon
      )
    end

    test "a next instant beyond 365 days is refused" do
      reference = utc("2026-01-01T00:00:00Z")
      beyond = DateTime.add(reference, ScheduleCalculator.max_horizon_seconds() + 1, :second)

      assert {:error, %Error{class: :validation, code: :schedule_horizon_exceeded}} =
               next(%{schedule_type: :once, run_at: DateTime.to_iso8601(beyond)}, reference)
    end

    test "an unknown IANA timezone is a validation error" do
      assert {:error, %Error{class: :validation, code: :unknown_timezone}} =
               next(
                 %{
                   schedule_type: :daily,
                   time_of_day: "09:00",
                   timezone: "Europe/Atlantis"
                 },
                 utc("2026-01-01T00:00:00Z")
               )
    end

    test "an invalid time of day is a validation error" do
      assert {:error, %Error{class: :validation, code: :invalid_time_of_day}} =
               next(
                 %{schedule_type: :daily, time_of_day: "24:00", timezone: "Etc/UTC"},
                 utc("2026-01-01T00:00:00Z")
               )
    end

    test "a runtime tzdata failure is a retryable dependency error" do
      assert {:error, %Error{class: :dependency, code: :tzdata_unavailable, retryable?: true}} =
               ScheduleCalculator.next(
                 %ScheduleConfig{
                   schedule_type: :daily,
                   time_of_day: "09:00",
                   timezone: "Europe/Belgrade"
                 },
                 utc("2026-01-01T00:00:00Z"),
                 time_zone_database: Calendar.UTCOnlyTimeZoneDatabase
               )
    end
  end

  describe "determinism" do
    test "the same config, reference, and tzdata version yield the same instant" do
      config = %{
        schedule_type: :weekly,
        time_of_day: "09:00:30",
        weekdays: ["monday"],
        timezone: "Europe/Belgrade"
      }

      reference = utc("2026-06-15T07:00:00Z")

      assert next(config, reference) == next(config, reference)
      assert ScheduleCalculator.tzdata_version() == "2026b"
    end

    test "an encoded configuration map is accepted" do
      struct = %ScheduleConfig{
        schedule_type: :every_hours,
        interval: 2,
        timezone: "Etc/UTC"
      }

      reference = utc("2026-01-01T00:00:00Z")
      expected = utc("2026-01-01T02:00:00Z")

      assert_next(struct, reference, expected)
      assert {:ok, got} = ScheduleCalculator.next(Config.encode(struct), reference)
      assert DateTime.compare(got, expected) == :eq
    end

    test "a zoned reference is converted to UTC before comparison" do
      {:ok, zoned} = DateTime.shift_zone(utc("2026-06-15T08:00:00Z"), "America/New_York")

      assert_next(
        %{schedule_type: :daily, time_of_day: "09:00", timezone: "Etc/UTC"},
        zoned,
        utc("2026-06-15T09:00:00Z")
      )
    end
  end

  defp next(attrs, reference) when is_map(attrs) and not is_struct(attrs) do
    ScheduleCalculator.next(config(attrs), reference)
  end

  defp next(%ScheduleConfig{} = config, reference) do
    ScheduleCalculator.next(config, reference)
  end

  defp assert_next(attrs, reference, expected) do
    assert {:ok, got} = next(attrs, reference)
    assert DateTime.compare(got, expected) == :eq, "#{got} != #{expected}"
    assert got.time_zone == "Etc/UTC"
  end

  defp config(attrs) do
    struct!(ScheduleConfig, Map.merge(%{timezone: "Etc/UTC"}, attrs))
  end

  defp utc(iso8601) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601)
    DateTime.from_unix!(DateTime.to_unix(datetime, :microsecond), :microsecond)
  end
end

defmodule PumbleAutomation.Workflows.ScheduleCalculator do
  @moduledoc """
  The next UTC instant a schedule will fire, from configuration and a reference.

  This module is pure. It does not read the clock, the Repo, or the server's
  local zone. The caller injects the exclusive reference instant. The same
  configuration, reference, and tzdata version therefore yield the same result.

  ## Exclusive reference

  The returned instant is strictly after `reference`. For an interval clock the
  caller must pass the prior *scheduled* instant, not the worker's completion
  time: adding the interval to a late completion would drift the grid. Daily
  and weekly clocks search for the next local occurrence after the reference.

  A one-time clock whose `run_at` is at or before the reference is terminal.

  ## DST (plan Section 23)

  Local times are converted through tzdata IANA identifiers.

    * Nonexistent local time (spring gap): the first valid instant after the gap.
    * Ambiguous local time (fall overlap): the earlier occurrence, once.

  Results are stored and returned as `Etc/UTC`.

  ## Bounds

  Interval clocks may not be shorter than one unit of their type (one minute or
  one hour) or longer than 8760 units. The next instant may not be more than
  365 days after the reference.

  ## Failures

  An unknown timezone or invalid local-time configuration is a validation
  error, for activation to refuse. A runtime tzdata failure is a retryable
  dependency error, for the dispatcher to pause and alert.
  """

  alias PumbleAutomation.Error
  alias PumbleAutomation.Limits
  alias PumbleAutomation.Workflows.Definition.ScheduleConfig
  alias PumbleAutomation.Workflows.Node.Config

  @min_interval 1
  @max_interval 8760
  @max_search_days 366
  @default_timezone "Etc/UTC"
  @probe_naive ~N[2026-01-01 00:00:00]

  @weekdays %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 7
  }

  @time_of_day_format ~r/\A([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?\z/

  @doc "The shortest interval a clock of either interval type may use."
  @spec min_interval() :: pos_integer()
  def min_interval, do: @min_interval

  @doc "The greatest number of seconds after the reference a next instant may fall."
  @spec max_horizon_seconds() :: pos_integer()
  def max_horizon_seconds, do: Limits.delay_seconds()

  @doc "The IANA tzdata release this node loaded, for example `\"2026b\"`."
  @spec tzdata_version() :: String.t()
  def tzdata_version, do: Tzdata.tzdata_version()

  @doc """
  Finds the single most-recent due occurrence without walking every missed slot.

  Interval clocks use arithmetic on their fixed UTC grid. Daily and weekly
  clocks inspect at most the previous eight local dates, then calculate the
  exact number of skipped calendar occurrences. The runtime cost is therefore
  bounded by schedule shape, not by how long the dispatcher was offline.
  """
  @spec latest_due(ScheduleConfig.t() | map(), DateTime.t(), DateTime.t()) ::
          {:ok,
           %{
             occurrence: DateTime.t(),
             next_run_at: DateTime.t() | nil,
             skipped: non_neg_integer()
           }}
          | {:error, Error.t()}
  def latest_due(config, first_occurrence, now)

  def latest_due(%{} = config, %DateTime{} = first_occurrence, %DateTime{} = now)
      when not is_struct(config) do
    case decode_config(config) do
      {:ok, decoded} -> latest_due(decoded, first_occurrence, now)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def latest_due(%ScheduleConfig{} = config, %DateTime{} = first_occurrence, %DateTime{} = now) do
    first_occurrence = utc_instant(first_occurrence)
    now = utc_instant(now)

    if DateTime.compare(first_occurrence, now) == :gt do
      {:error, invalid_config("The first occurrence is not due yet.")}
    else
      latest_due(config, first_occurrence, now, config.schedule_type)
    end
  end

  @doc """
  The next UTC instant strictly after `reference`, or `:terminal`.

  `config` is a `ScheduleConfig` or an encoded string-keyed map of the same
  fields. `opts` may pass `:time_zone_database` to inject the Calendar database;
  the process default is used otherwise.
  """
  @spec next(ScheduleConfig.t() | map(), DateTime.t(), keyword()) ::
          {:ok, DateTime.t()} | {:ok, :terminal} | {:error, Error.t()}
  def next(config, reference, opts \\ [])

  def next(%ScheduleConfig{} = config, %DateTime{} = reference, opts) when is_list(opts) do
    db = Keyword.get(opts, :time_zone_database, Calendar.get_time_zone_database())
    reference = utc_instant(reference)

    with :ok <- check_timezone(timezone(config), db),
         {:ok, result} <- compute(config, reference, db) do
      bound_horizon(result, reference)
    end
  end

  def next(%{} = config, %DateTime{} = reference, opts)
      when not is_struct(config) and is_list(opts) do
    case decode_config(config) do
      {:ok, struct} -> next(struct, reference, opts)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp latest_due(%ScheduleConfig{} = config, first, _now, :once) do
    with :ok <- check_timezone(timezone(config), Calendar.get_time_zone_database()) do
      {:ok, %{occurrence: first, next_run_at: nil, skipped: 0}}
    end
  end

  defp latest_due(%ScheduleConfig{interval: interval} = config, first, now, :every_minutes) do
    latest_interval(config, first, now, interval, 60)
  end

  defp latest_due(%ScheduleConfig{interval: interval} = config, first, now, :every_hours) do
    latest_interval(config, first, now, interval, 60 * 60)
  end

  defp latest_due(%ScheduleConfig{} = config, first, now, :daily) do
    latest_calendar(config, first, now, MapSet.new(1..7))
  end

  defp latest_due(%ScheduleConfig{} = config, first, now, :weekly) do
    with {:ok, days} <- weekday_set(config.weekdays) do
      latest_calendar(config, first, now, days)
    end
  end

  defp latest_due(%ScheduleConfig{}, _first, _now, _type) do
    {:error, invalid_config("This is not a supported schedule type.")}
  end

  defp latest_interval(config, first, now, interval, unit_seconds) do
    with :ok <- check_interval(interval),
         :ok <- check_timezone(timezone(config), Calendar.get_time_zone_database()) do
      interval_seconds = interval * unit_seconds
      skipped = div(DateTime.diff(now, first, :second), interval_seconds)
      occurrence = DateTime.add(first, skipped * interval_seconds, :second)

      {:ok,
       %{
         occurrence: occurrence,
         next_run_at: DateTime.add(occurrence, interval_seconds, :second),
         skipped: skipped
       }}
    end
  end

  defp latest_calendar(config, first, now, days) do
    db = Calendar.get_time_zone_database()
    zone = timezone(config)

    with :ok <- check_timezone(zone, db),
         {:ok, time} <- parse_time_of_day(config.time_of_day),
         {:ok, now_date} <- local_date(now, zone, db),
         {:ok, first_date} <- local_date(first, zone, db),
         {:ok, occurrence} <-
           find_latest_local(now_date, time, zone, days, first, now, db, 8),
         {:ok, next_run_at} <- next(config, occurrence, time_zone_database: db) do
      skipped = calendar_skipped(first_date, occurrence, zone, days, db)

      {:ok, %{occurrence: occurrence, next_run_at: next_run_at, skipped: skipped}}
    end
  end

  defp find_latest_local(_date, _time, _zone, _days, _first, _now, _db, remaining)
       when remaining <= 0 do
    {:error, horizon_exceeded()}
  end

  defp find_latest_local(date, time, zone, days, first, now, db, remaining) do
    result =
      if MapSet.member?(days, Date.day_of_week(date)) do
        date
        |> local_occurrence(time, zone, db)
        |> eligible_occurrence(first, now)
      else
        :continue
      end

    case result do
      {:ok, occurrence} ->
        {:ok, occurrence}

      {:error, %Error{} = error} ->
        {:error, error}

      :continue ->
        find_latest_local(Date.add(date, -1), time, zone, days, first, now, db, remaining - 1)
    end
  end

  defp eligible_occurrence({:ok, occurrence}, first, now) do
    if DateTime.compare(occurrence, first) != :lt and DateTime.compare(occurrence, now) != :gt do
      {:ok, occurrence}
    else
      :continue
    end
  end

  defp eligible_occurrence({:error, %Error{} = error}, _first, _now), do: {:error, error}

  defp calendar_skipped(first_date, occurrence, zone, days, db) do
    {:ok, occurrence_date} = local_date(occurrence, zone, db)
    days_after_first = Date.diff(occurrence_date, first_date)

    if days_after_first <= 0 do
      0
    else
      full_weeks = div(days_after_first, 7)
      remainder = rem(days_after_first, 7)

      full_weeks * MapSet.size(days) +
        count_remainder_days(first_date, days, remainder)
    end
  end

  defp count_remainder_days(_first_date, _days, 0), do: 0

  defp count_remainder_days(first_date, days, remainder) do
    1..remainder
    |> Enum.count(fn offset ->
      MapSet.member?(days, Date.day_of_week(Date.add(first_date, offset)))
    end)
  end

  defp decode_config(config) do
    case Config.decode(ScheduleConfig, stringify(config), "/config") do
      {:ok, struct} -> {:ok, struct}
      {:error, issues} -> {:error, invalid_config(config_issue_message(issues))}
    end
  end

  defp stringify(config) do
    Map.new(config, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_atom(value) and value not in [true, false, nil] do
    Atom.to_string(value)
  end

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp compute(%ScheduleConfig{schedule_type: :once} = config, reference, db) do
    once_next(config, reference, db)
  end

  defp compute(%ScheduleConfig{schedule_type: :every_minutes} = config, reference, _db) do
    interval_next(config, reference, :minute)
  end

  defp compute(%ScheduleConfig{schedule_type: :every_hours} = config, reference, _db) do
    interval_next(config, reference, :hour)
  end

  defp compute(%ScheduleConfig{schedule_type: :daily} = config, reference, db) do
    daily_next(config, reference, db)
  end

  defp compute(%ScheduleConfig{schedule_type: :weekly} = config, reference, db) do
    weekly_next(config, reference, db)
  end

  defp compute(%ScheduleConfig{}, _reference, _db) do
    {:error, invalid_config("This is not a supported schedule type.")}
  end

  defp once_next(%ScheduleConfig{run_at: run_at} = config, reference, db) do
    case parse_run_at(run_at, timezone(config), db) do
      {:ok, instant} -> after_or_terminal(instant, reference)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp after_or_terminal(instant, reference) do
    if DateTime.compare(instant, reference) == :gt do
      {:ok, instant}
    else
      {:ok, :terminal}
    end
  end

  defp parse_run_at(value, timezone, db) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, utc_instant(datetime)}
      {:error, _reason} -> parse_naive_run_at(value, timezone, db)
    end
  end

  defp parse_run_at(_value, _timezone, _db) do
    {:error, invalid_run_at()}
  end

  defp parse_naive_run_at(value, timezone, db) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> wall_to_utc(naive, timezone, db)
      {:error, _reason} -> {:error, invalid_run_at()}
    end
  end

  defp interval_next(%ScheduleConfig{interval: interval}, reference, unit) do
    case check_interval(interval) do
      :ok -> {:ok, DateTime.add(reference, interval, unit)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp check_interval(interval) when is_integer(interval) and interval < @min_interval do
    {:error, interval_too_small()}
  end

  defp check_interval(interval) when is_integer(interval) and interval > @max_interval do
    {:error, invalid_config("This value is outside the allowed range.")}
  end

  defp check_interval(interval) when is_integer(interval), do: :ok

  defp check_interval(_interval) do
    {:error, invalid_config("This schedule type needs an interval.")}
  end

  defp daily_next(%ScheduleConfig{} = config, reference, db) do
    with {:ok, time} <- parse_time_of_day(config.time_of_day),
         {:ok, start_date} <- local_date(reference, timezone(config), db) do
      search_local(
        start_date,
        time,
        timezone(config),
        MapSet.new(1..7),
        reference,
        db,
        @max_search_days
      )
    end
  end

  defp weekly_next(%ScheduleConfig{} = config, reference, db) do
    with {:ok, time} <- parse_time_of_day(config.time_of_day),
         {:ok, days} <- weekday_set(config.weekdays),
         {:ok, start_date} <- local_date(reference, timezone(config), db) do
      search_local(start_date, time, timezone(config), days, reference, db, @max_search_days)
    end
  end

  defp weekday_set(weekdays) when is_list(weekdays) and weekdays != [] do
    mapped = Enum.map(weekdays, &Map.get(@weekdays, &1))

    if Enum.any?(mapped, &is_nil/1) do
      {:error, invalid_config("This is not a weekday.")}
    else
      {:ok, MapSet.new(mapped)}
    end
  end

  defp weekday_set(_weekdays) do
    {:error, invalid_config("This schedule type needs this field.")}
  end

  defp search_local(_date, _time, _timezone, _days, _reference, _db, remaining)
       when remaining <= 0 do
    {:error, horizon_exceeded()}
  end

  defp search_local(date, time, timezone, days, reference, db, remaining) do
    if MapSet.member?(days, Date.day_of_week(date)) do
      consider_occurrence(date, time, timezone, days, reference, db, remaining)
    else
      search_local(Date.add(date, 1), time, timezone, days, reference, db, remaining - 1)
    end
  end

  defp consider_occurrence(date, time, timezone, days, reference, db, remaining) do
    case local_occurrence(date, time, timezone, db) do
      {:ok, utc} ->
        take_or_continue(utc, date, time, timezone, days, reference, db, remaining)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp take_or_continue(utc, date, time, timezone, days, reference, db, remaining) do
    if DateTime.compare(utc, reference) == :gt do
      {:ok, utc}
    else
      search_local(Date.add(date, 1), time, timezone, days, reference, db, remaining - 1)
    end
  end

  defp local_occurrence(date, time, timezone, db) do
    wall_to_utc(NaiveDateTime.new!(date, time), timezone, db)
  end

  defp parse_time_of_day(value) when is_binary(value) do
    if Regex.match?(@time_of_day_format, value) do
      time_from_parts(String.split(value, ":"))
    else
      {:error, invalid_time_of_day()}
    end
  end

  defp parse_time_of_day(_value), do: {:error, invalid_time_of_day()}

  defp time_from_parts([hour, minute]) do
    build_time(String.to_integer(hour), String.to_integer(minute), 0)
  end

  defp time_from_parts([hour, minute, second]) do
    build_time(String.to_integer(hour), String.to_integer(minute), String.to_integer(second))
  end

  defp time_from_parts(_parts), do: {:error, invalid_time_of_day()}

  defp build_time(hour, minute, second) do
    case Time.new(hour, minute, second) do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> {:error, invalid_time_of_day()}
    end
  end

  defp timezone(%ScheduleConfig{timezone: timezone})
       when is_binary(timezone) and timezone != "" do
    timezone
  end

  defp timezone(%ScheduleConfig{}), do: @default_timezone

  defp check_timezone(timezone, db) when is_binary(timezone) and timezone != "" do
    case DateTime.from_naive(@probe_naive, timezone, db) do
      {:ok, _datetime} -> :ok
      {:ambiguous, _first, _second} -> :ok
      {:gap, _before, _after} -> :ok
      {:error, :time_zone_not_found} -> {:error, unknown_timezone()}
      {:error, reason} -> {:error, tzdata_unavailable(reason)}
    end
  rescue
    exception -> {:error, tzdata_unavailable(exception)}
  end

  defp check_timezone(_timezone, _db), do: {:error, unknown_timezone()}

  defp local_date(reference, timezone, db) do
    case DateTime.shift_zone(reference, timezone, db) do
      {:ok, local} -> {:ok, DateTime.to_date(local)}
      {:error, :time_zone_not_found} -> {:error, unknown_timezone()}
      {:error, reason} -> {:error, tzdata_unavailable(reason)}
    end
  rescue
    exception -> {:error, tzdata_unavailable(exception)}
  end

  defp wall_to_utc(naive, timezone, db) do
    case DateTime.from_naive(naive, timezone, db) do
      {:ok, datetime} -> {:ok, utc_instant(datetime)}
      {:ambiguous, first, _second} -> {:ok, utc_instant(first)}
      {:gap, _before, after_gap} -> {:ok, utc_instant(after_gap)}
      {:error, :time_zone_not_found} -> {:error, unknown_timezone()}
      {:error, reason} -> {:error, tzdata_unavailable(reason)}
    end
  rescue
    exception -> {:error, tzdata_unavailable(exception)}
  end

  defp bound_horizon(:terminal, _reference), do: {:ok, :terminal}

  defp bound_horizon(%DateTime{} = next, %DateTime{} = reference) do
    limit = DateTime.add(reference, max_horizon_seconds(), :second)

    case DateTime.compare(next, limit) do
      :gt -> {:error, horizon_exceeded()}
      _cmp -> {:ok, next}
    end
  end

  defp utc_instant(%DateTime{} = datetime) do
    DateTime.from_unix!(DateTime.to_unix(datetime, :microsecond), :microsecond)
  end

  defp unknown_timezone do
    Error.new(:validation, :unknown_timezone, message: "This is not a known time zone.")
  end

  defp invalid_run_at do
    Error.new(:validation, :invalid_run_at, message: "This is not a date and time.")
  end

  defp invalid_time_of_day do
    Error.new(:validation, :invalid_time_of_day, message: "This is not a time of day.")
  end

  defp invalid_config(message) do
    Error.new(:validation, :invalid_schedule_config, message: message)
  end

  defp config_issue_message([%{message: message} | _rest]), do: message
  defp config_issue_message(_issues), do: "This schedule is not valid."

  defp interval_too_small do
    Error.new(:validation, :interval_too_small,
      message: "The interval is shorter than the minimum."
    )
  end

  defp horizon_exceeded do
    Error.new(:validation, :schedule_horizon_exceeded,
      message: "The next run is beyond the allowed horizon."
    )
  end

  defp tzdata_unavailable(reason) do
    Error.new(:dependency, :tzdata_unavailable,
      message: "The time zone database is unavailable.",
      retryable?: true,
      details: %{reason: reason_detail(reason)}
    )
  end

  defp reason_detail(%_{} = exception), do: Exception.message(exception)
  defp reason_detail(reason) when is_atom(reason), do: Atom.to_string(reason)
end

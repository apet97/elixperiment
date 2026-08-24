defmodule PumbleAutomation.Audit do
  @moduledoc """
  Tenant-scoped, append-only audit history for operators.

  The LiveView reads through this module. There is no update and no delete.
  Metadata is already allowlisted at write time; this module never selects a
  payload, a token, or a secret value.
  """

  import Ecto.Query

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Error
  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Repo
  alias PumbleAutomation.Scope

  @default_limit 20
  @max_limit 50

  @doc "The default page size for the audit index."
  @spec page_size() :: pos_integer()
  def page_size, do: @default_limit

  @doc """
  One page of audit events, newest first, with a cursor for the next page.

  Options: `:limit`, `:cursor`, `:action`, `:actor_id`, `:resource_type`,
  `:from`, `:until`.
  """
  @spec list(Scope.t(), keyword()) ::
          {:ok, %{entries: [AuditEvent.t()], next_cursor: String.t() | nil}}
          | {:error, Error.t()}
  def list(%Scope{} = scope, opts \\ []) do
    with :ok <- Policy.authorize(scope, :read_workflows),
         {:ok, filters} <- parse_filters(opts) do
      limit = filters.limit
      rows = Repo.all(index_query(scope, filters, limit + 1))
      {entries, rest} = Enum.split(rows, limit)
      next_cursor = if rest == [], do: nil, else: encode_cursor(List.last(entries))
      {:ok, %{entries: entries, next_cursor: next_cursor}}
    end
  end

  defp index_query(%Scope{} = scope, filters, limit) do
    AuditEvent
    |> from(as: :event)
    |> where_tenant(scope.installation_id)
    |> where_action(filters.action)
    |> where_actor(filters.actor_id)
    |> where_resource(filters.resource_type)
    |> where_from(filters.from)
    |> where_until(filters.until)
    |> where_cursor(filters.cursor)
    |> order_by([event: event], desc: event.inserted_at, desc: event.id)
    |> limit(^limit)
  end

  defp where_tenant(query, installation_id) do
    from [event: event] in query, where: event.installation_id == ^installation_id
  end

  defp where_action(query, nil), do: query

  defp where_action(query, action) do
    from [event: event] in query, where: event.action == ^action
  end

  defp where_actor(query, nil), do: query

  defp where_actor(query, actor_id) do
    from [event: event] in query, where: event.actor_id == ^actor_id
  end

  defp where_resource(query, nil), do: query

  defp where_resource(query, resource_type) do
    from [event: event] in query, where: event.resource_type == ^resource_type
  end

  defp where_from(query, nil), do: query

  defp where_from(query, %DateTime{} = from) do
    from [event: event] in query, where: event.inserted_at >= ^from
  end

  defp where_until(query, nil), do: query

  defp where_until(query, %DateTime{} = until) do
    from [event: event] in query, where: event.inserted_at <= ^until
  end

  defp where_cursor(query, nil), do: query

  defp where_cursor(query, {time, id}) do
    from [event: event] in query,
      where:
        event.inserted_at < ^time or
          (event.inserted_at == ^time and event.id < ^id)
  end

  defp parse_filters(opts) do
    with {:ok, action} <- optional_text(opts, :action),
         {:ok, actor_id} <- optional_text(opts, :actor_id),
         {:ok, resource_type} <- optional_text(opts, :resource_type),
         {:ok, from} <- optional_time(opts, :from),
         {:ok, until} <- optional_time(opts, :until),
         {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)) do
      {:ok,
       %{
         action: action,
         actor_id: actor_id,
         resource_type: resource_type,
         from: from,
         until: until,
         cursor: cursor,
         limit: clamp_limit(Keyword.get(opts, :limit))
       }}
    end
  end

  defp optional_text(opts, key) do
    case Keyword.get(opts, key) do
      value when value in [nil, ""] -> {:ok, nil}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _other -> {:ok, nil}
    end
  end

  defp optional_time(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      %DateTime{} = time -> {:ok, time}
      value when is_binary(value) -> parse_time(value)
      _other -> {:ok, nil}
    end
  end

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} ->
        {:ok, DateTime.from_unix!(DateTime.to_unix(time, :microsecond), :microsecond)}

      {:error, _reason} ->
        parse_naive_time(value)
    end
  end

  defp parse_naive_time(value) do
    case value |> String.replace("T", " ") |> pad_seconds() |> NaiveDateTime.from_iso8601() do
      {:ok, naive} ->
        case DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, time} -> {:ok, time}
          _other -> {:ok, nil}
        end

      {:error, _reason} ->
        {:ok, nil}
    end
  end

  defp pad_seconds(
         <<date::binary-size(10), " ", hour::binary-size(2), ":", minute::binary-size(2)>>
       ) do
    date <> " " <> hour <> ":" <> minute <> ":00"
  end

  defp pad_seconds(value), do: value

  defp encode_cursor(%AuditEvent{inserted_at: %DateTime{} = time, id: id}) do
    Base.url_encode64("#{DateTime.to_iso8601(time)} #{id}", padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(""), do: {:ok, nil}

  defp decode_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- decode64(value),
         [time_text, id] <- String.split(decoded, " ", parts: 2),
         {:ok, time, _offset} <- DateTime.from_iso8601(time_text),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, {time, uuid}}
    else
      _invalid -> {:ok, nil}
    end
  end

  defp decode_cursor(_value), do: {:ok, nil}

  defp decode64(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> :error
    end
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_limit), do: @default_limit
end

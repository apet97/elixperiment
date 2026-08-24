defmodule PumbleAutomation.Ingress.WebhookEndpoint do
  @moduledoc """
  One tenant-owned inbound webhook URL and its credentials.

  The plaintext token is 256 random bits, shown once, and never written here.
  `:token_digest` is HMAC-SHA256 of that token keyed with this release's
  `secret_key_base`. A 256-bit token does not need a slow password hash; HMAC
  is enough to keep a stolen row from being presented as a credential, and it
  stays cheap under webhook load.

  ## Rotation overlap

  `:previous_token_digest` and `:previous_token_expires_at` travel together.
  During the overlap window `authenticates?/3` accepts either digest. After
  expiry only the current digest matches, and a later write clears the pair.

  When `:require_signature` is true, the HMAC secret is encrypted through the
  versioned application vault. It is deliberately `load_in_query: false`; list
  and lifecycle queries cannot decrypt it by accident. Only the authentication
  query and owner-only rotation query select that field explicitly. The prior
  signing secret has the same bounded overlap semantics as the bearer token.

  ## Body signature scheme

  The fixed header is `x-webhook-signature`. Its value is exactly
  `sha256=<64 lowercase hexadecimal characters>`, where the digest is
  `HMAC-SHA256(signing_secret, raw_request_body)`. The canonical input is the
  byte-for-byte HTTP request body, with no JSON re-encoding, timestamp, prefix,
  or newline normalization. `signature_valid?/4` decodes the supplied digest
  and uses constant-time comparison.

  Signature-required rows keep the previous release's `enabled` column false
  and use `signature_enabled` as their active bit. The previous binary does not
  understand raw-body signatures, so it sees those rows as disabled and fails
  closed after a rollback. This release uses `enabled?/1` for the effective
  state. Bearer-only rows continue to use `enabled`.

  ## Binding

  An endpoint names one workflow and one immutable version of that workflow,
  under the same installation. It cannot choose an arbitrary version at
  request time; P8-T07 creates executions against this stored binding.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PumbleAutomation.Crypto.EncryptedBinary
  alias PumbleAutomation.Crypto.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @digest_bytes 32
  @token_bytes 32
  @signing_secret_bytes 32
  @signature_bytes 32
  @signature_prefix "sha256="
  @public_id_bytes 16
  @rotation_overlap_seconds 3600
  @public_id_min 16
  @public_id_max 64
  @rate_limit_min 1
  @rate_limit_max 10_000
  @default_rate_limit_per_minute 60
  @default_rate_limit_per_ip 30

  @fields ~w(installation_id workflow_id workflow_version_id public_id token_digest
             previous_token_digest previous_token_expires_at enabled last_used_at
             rate_limit_per_minute rate_limit_per_ip_per_minute require_signature
             signing_secret signing_secret_key_version previous_signing_secret
             previous_signing_secret_key_version previous_signing_secret_expires_at)a

  @derive {Inspect,
           except: [
             :token_digest,
             :previous_token_digest,
             :signing_secret,
             :previous_signing_secret
           ]}

  @type t :: %__MODULE__{}

  schema "webhook_endpoints" do
    field :installation_id, :binary_id
    field :workflow_id, :binary_id
    field :workflow_version_id, :binary_id
    field :public_id, :string
    field :token_digest, :binary, redact: true
    field :previous_token_digest, :binary, redact: true
    field :previous_token_expires_at, :utc_datetime_usec
    field :enabled, :boolean, default: true
    field :last_used_at, :utc_datetime_usec
    field :rate_limit_per_minute, :integer, default: @default_rate_limit_per_minute
    field :rate_limit_per_ip_per_minute, :integer, default: @default_rate_limit_per_ip
    field :require_signature, :boolean, default: false
    field :signature_enabled, :boolean, default: false

    field :signing_secret, EncryptedBinary,
      aad: "webhook_endpoints.signing_secret",
      load_in_query: false,
      redact: true

    field :signing_secret_key_version, :integer

    field :previous_signing_secret, EncryptedBinary,
      aad: "webhook_endpoints.previous_signing_secret",
      load_in_query: false,
      redact: true

    field :previous_signing_secret_key_version, :integer
    field :previous_signing_secret_expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert or an update.

  `:installation_id`, `:workflow_id`, `:workflow_version_id`, `:public_id`,
  and `:token_digest` are required. The plaintext token is not a field.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = endpoint, attrs) do
    endpoint
    |> cast(attrs, @fields)
    |> route_enabled(attrs)
    |> validate_required([
      :installation_id,
      :workflow_id,
      :workflow_version_id,
      :public_id,
      :token_digest
    ])
    |> validate_length(:public_id, min: @public_id_min, max: @public_id_max)
    |> validate_number(:rate_limit_per_minute,
      greater_than_or_equal_to: @rate_limit_min,
      less_than_or_equal_to: @rate_limit_max
    )
    |> validate_number(:rate_limit_per_ip_per_minute,
      greater_than_or_equal_to: @rate_limit_min,
      less_than_or_equal_to: @rate_limit_max
    )
    |> validate_digest(:token_digest)
    |> validate_digest(:previous_token_digest)
    |> validate_previous_token_pair()
    |> validate_signing_secret_pairs()
    |> validate_number(:signing_secret_key_version, greater_than: 0, less_than: 256)
    |> validate_number(:previous_signing_secret_key_version, greater_than: 0, less_than: 256)
    |> unique_constraint(:public_id, name: :webhook_endpoints_public_id_index)
    |> unique_constraint(:token_digest, name: :webhook_endpoints_token_digest_index)
    |> check_constraint(:public_id, name: :webhook_endpoints_public_id_check)
    |> check_constraint(:token_digest, name: :webhook_endpoints_token_digest_check)
    |> check_constraint(:previous_token_digest,
      name: :webhook_endpoints_previous_token_digest_check
    )
    |> check_constraint(:previous_token_expires_at,
      name: :webhook_endpoints_previous_token_pair_check
    )
    |> check_constraint(:signing_secret, name: :webhook_endpoints_signing_secret_pair_check)
    |> check_constraint(:signing_secret,
      name: :webhook_endpoints_signing_secret_envelope_check
    )
    |> check_constraint(:enabled, name: :webhook_endpoints_signature_compatibility_check)
    |> check_constraint(:previous_signing_secret,
      name: :webhook_endpoints_previous_signing_secret_pair_check
    )
    |> check_constraint(:previous_signing_secret,
      name: :webhook_endpoints_previous_signing_secret_envelope_check
    )
    |> check_constraint(:rate_limit_per_minute,
      name: :webhook_endpoints_rate_limit_per_minute_check
    )
    |> check_constraint(:rate_limit_per_ip_per_minute,
      name: :webhook_endpoints_rate_limit_per_ip_per_minute_check
    )
    |> foreign_key_constraint(:installation_id)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:workflow_version_id)
  end

  @doc "Whether this release may accept deliveries for the endpoint."
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{require_signature: true, enabled: false, signature_enabled: enabled}),
    do: enabled == true

  def enabled?(%__MODULE__{require_signature: false, enabled: enabled, signature_enabled: false}),
    do: enabled == true

  def enabled?(%__MODULE__{}), do: false

  @doc "HMAC-SHA256 of a webhook bearer token, keyed with this release's secret."
  @spec digest(binary()) :: binary()
  def digest(token) when is_binary(token), do: :crypto.mac(:hmac, :sha256, hmac_key(), token)

  @doc "The number of bytes `digest/1` returns."
  @spec digest_bytes() :: pos_integer()
  def digest_bytes, do: @digest_bytes

  @doc "The number of random bytes a newly issued token holds."
  @spec token_bytes() :: pos_integer()
  def token_bytes, do: @token_bytes

  @doc "How long a replaced token remains valid, in seconds."
  @spec rotation_overlap_seconds() :: pos_integer()
  def rotation_overlap_seconds, do: @rotation_overlap_seconds

  @doc "A 256-bit bearer token. Callers show it once and store `digest/1` of it."
  @spec generate_token() :: binary()
  def generate_token, do: :crypto.strong_rand_bytes(@token_bytes)

  @doc "A URL-safe, 256-bit HMAC key suitable for showing once to a caller."
  @spec generate_signing_secret() :: String.t()
  def generate_signing_secret do
    @signing_secret_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc "The configured primary vault version for a newly encrypted signing secret."
  @spec signing_secret_key_version() :: pos_integer()
  def signing_secret_key_version, do: Vault.keyring().primary_version

  @doc "Signs the exact raw request bytes using the generic webhook scheme."
  @spec sign_body(binary(), binary()) :: String.t()
  def sign_body(secret, raw_body) when is_binary(secret) and is_binary(raw_body) do
    digest = :crypto.mac(:hmac, :sha256, secret, raw_body)
    @signature_prefix <> Base.encode16(digest, case: :lower)
  end

  @doc "Whether the supplied generic-webhook signature authenticates these raw bytes."
  @spec signature_valid?(t(), String.t() | nil, binary(), DateTime.t()) :: boolean()
  def signature_valid?(endpoint, signature, raw_body, now \\ DateTime.utc_now())

  def signature_valid?(%__MODULE__{require_signature: false}, _signature, raw_body, _now)
      when is_binary(raw_body),
      do: true

  def signature_valid?(%__MODULE__{require_signature: true} = endpoint, signature, raw_body, now)
      when is_binary(raw_body) do
    case decode_signature(signature) do
      {:ok, supplied} ->
        current = signature_digest(endpoint.signing_secret, raw_body)

        previous_secret = endpoint.previous_signing_secret || endpoint.signing_secret
        previous = signature_digest(previous_secret, raw_body)

        current_matches = secure_digest_compare(current, supplied)
        previous_matches = secure_digest_compare(previous, supplied)

        current_matches or
          (previous_signing_secret_valid?(endpoint, now) and previous_matches)

      :error ->
        false
    end
  end

  def signature_valid?(_endpoint, _signature, _raw_body, _now), do: false

  @doc "An opaque public id for the URL path, unique across tenants."
  @spec generate_public_id() :: String.t()
  def generate_public_id do
    Base.url_encode64(:crypto.strong_rand_bytes(@public_id_bytes), padding: false)
  end

  @doc """
  Whether `token` matches this endpoint's current digest, or a previous digest
  that has not yet expired at `now`.
  """
  @spec authenticates?(t(), binary(), DateTime.t()) :: boolean()
  def authenticates?(%__MODULE__{} = endpoint, token, now \\ DateTime.utc_now())
      when is_binary(token) do
    digest_matches?(endpoint.token_digest, token) or
      previous_digest_valid?(endpoint, token, now)
  end

  @doc "The unscoped lookup the public URL uses: one public id, at most one row."
  @spec by_public_id(String.t()) :: Ecto.Query.t()
  def by_public_id(public_id) when is_binary(public_id) do
    from e in __MODULE__, where: e.public_id == ^public_id
  end

  @doc "The public lookup that explicitly loads encrypted signing fields for verification."
  @spec by_public_id_for_auth(String.t()) :: Ecto.Query.t()
  def by_public_id_for_auth(public_id) when is_binary(public_id) do
    from e in __MODULE__,
      where: e.public_id == ^public_id,
      select_merge: %{
        signing_secret: e.signing_secret,
        previous_signing_secret: e.previous_signing_secret
      }
  end

  @doc "Tenant-scoped lookup that loads signing fields only for owner credential rotation."
  @spec by_id_for_rotation(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def by_id_for_rotation(installation_id, id)
      when is_binary(installation_id) and is_binary(id) do
    from e in __MODULE__,
      where: e.installation_id == ^installation_id and e.id == ^id,
      select_merge: %{
        signing_secret: e.signing_secret,
        previous_signing_secret: e.previous_signing_secret
      }
  end

  @doc """
  The tenant-scoped lookup.

  A public id that belongs to another installation does not match, even when
  the caller knows the id.
  """
  @spec by_public_id(Ecto.UUID.t(), String.t()) :: Ecto.Query.t()
  def by_public_id(installation_id, public_id)
      when is_binary(installation_id) and is_binary(public_id) do
    from e in __MODULE__,
      where: e.installation_id == ^installation_id and e.public_id == ^public_id
  end

  defp hmac_key do
    Application.fetch_env!(:pumble_automation, PumbleAutomationWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end

  defp digest_matches?(digest, token)
       when is_binary(digest) and is_binary(token) and byte_size(digest) == @digest_bytes do
    expected = digest(token)
    byte_size(expected) == byte_size(digest) and Plug.Crypto.secure_compare(digest, expected)
  end

  defp digest_matches?(_digest, _token), do: false

  defp previous_digest_valid?(
         %__MODULE__{
           previous_token_digest: digest,
           previous_token_expires_at: %DateTime{} = expires_at
         },
         token,
         now
       )
       when is_binary(digest) do
    DateTime.compare(expires_at, now) == :gt and digest_matches?(digest, token)
  end

  defp previous_digest_valid?(_endpoint, _token, _now), do: false

  defp decode_signature(@signature_prefix <> encoded) when byte_size(encoded) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, encoded) do
      Base.decode16(encoded, case: :lower)
    else
      :error
    end
  end

  defp decode_signature(_signature), do: :error

  defp signature_digest(secret, raw_body) when is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, raw_body)
  end

  defp signature_digest(_secret, _raw_body), do: :binary.copy(<<0>>, @signature_bytes)

  defp secure_digest_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == @signature_bytes and
              byte_size(right) == @signature_bytes do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_digest_compare(_left, _right), do: false

  defp previous_signing_secret_valid?(
         %__MODULE__{
           previous_signing_secret: secret,
           previous_signing_secret_expires_at: %DateTime{} = expires_at
         },
         now
       )
       when is_binary(secret) do
    DateTime.compare(expires_at, now) == :gt
  end

  defp previous_signing_secret_valid?(_endpoint, _now), do: false

  defp validate_digest(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      digest when is_binary(digest) and byte_size(digest) == @digest_bytes ->
        changeset

      _other ->
        add_error(changeset, field, "must be a 32 byte keyed SHA-256 digest")
    end
  end

  defp route_enabled(changeset, attrs) do
    requested = requested_enabled(changeset, attrs)

    if get_field(changeset, :require_signature) == true do
      changeset
      |> put_change(:enabled, false)
      |> put_change(:signature_enabled, requested)
    else
      changeset
      |> put_change(:enabled, requested)
      |> put_change(:signature_enabled, false)
    end
  end

  defp requested_enabled(changeset, attrs) do
    case Map.fetch(attrs, :enabled) do
      {:ok, value} -> enabled_value?(value)
      :error -> requested_enabled_string(changeset, attrs)
    end
  end

  defp requested_enabled_string(changeset, attrs) do
    case Map.fetch(attrs, "enabled") do
      {:ok, value} -> enabled_value?(value)
      :error -> enabled?(changeset.data)
    end
  end

  defp enabled_value?(value), do: value in [true, "true", "1", 1]

  defp validate_previous_token_pair(changeset) do
    digest = get_field(changeset, :previous_token_digest)
    expires_at = get_field(changeset, :previous_token_expires_at)

    cond do
      is_nil(digest) and is_nil(expires_at) ->
        changeset

      not is_nil(digest) and not is_nil(expires_at) ->
        changeset

      is_nil(digest) ->
        add_error(changeset, :previous_token_digest, "must accompany previous_token_expires_at")

      true ->
        add_error(changeset, :previous_token_expires_at, "must accompany previous_token_digest")
    end
  end

  defp validate_signing_secret_pairs(changeset) do
    required? = get_field(changeset, :require_signature)
    current = get_field(changeset, :signing_secret)
    current_version = get_field(changeset, :signing_secret_key_version)
    previous = get_field(changeset, :previous_signing_secret)
    previous_version = get_field(changeset, :previous_signing_secret_key_version)
    previous_expires_at = get_field(changeset, :previous_signing_secret_expires_at)

    changeset
    |> validate_current_signing_pair(required?, current, current_version)
    |> validate_previous_signing_pair(required?, previous, previous_version, previous_expires_at)
  end

  defp validate_current_signing_pair(changeset, true, secret, version)
       when is_binary(secret) and is_integer(version),
       do: changeset

  defp validate_current_signing_pair(changeset, true, secret, version) do
    changeset
    |> maybe_pair_error(:signing_secret, secret, "is required when signatures are enabled")
    |> maybe_pair_error(
      :signing_secret_key_version,
      version,
      "is required when signatures are enabled"
    )
  end

  defp validate_current_signing_pair(changeset, false, nil, nil), do: changeset

  defp validate_current_signing_pair(changeset, false, _secret, _version) do
    add_error(changeset, :signing_secret, "must be empty when signatures are disabled")
  end

  defp validate_previous_signing_pair(changeset, _required?, nil, nil, nil), do: changeset

  defp validate_previous_signing_pair(changeset, true, secret, version, %DateTime{})
       when is_binary(secret) and is_integer(version),
       do: changeset

  defp validate_previous_signing_pair(changeset, _required?, _secret, _version, _expires_at) do
    add_error(
      changeset,
      :previous_signing_secret,
      "must have a key version and expiry, and signatures must be enabled"
    )
  end

  defp maybe_pair_error(changeset, _field, value, _message) when not is_nil(value), do: changeset
  defp maybe_pair_error(changeset, field, nil, message), do: add_error(changeset, field, message)
end

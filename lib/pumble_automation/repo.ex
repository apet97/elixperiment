defmodule PumbleAutomation.Repo do
  use Ecto.Repo,
    otp_app: :pumble_automation,
    adapter: Ecto.Adapters.Postgres
end

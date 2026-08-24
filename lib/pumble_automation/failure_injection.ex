defmodule PumbleAutomation.FailureInjection do
  @moduledoc false

  # Test-only crash hooks. In `:test` this forwards to
  # `PumbleAutomation.FailureInjector`. Every other Mix env compiles a no-op,
  # so the injector is absent from a release's module surface.

  @compile {:inline, crash: 1, crash_if_ambiguous: 1}

  @env Mix.env()

  if @env == :test do
    @spec crash(atom()) :: :ok
    def crash(boundary) when is_atom(boundary) do
      PumbleAutomation.FailureInjector.maybe_crash(boundary)
    end

    @spec crash_if_ambiguous(term()) :: term()
    def crash_if_ambiguous(result) do
      if ambiguous_write?(result) do
        PumbleAutomation.FailureInjector.maybe_crash(:after_write_timeout)
      end

      result
    end

    defp ambiguous_write?({:error, %{class: class}})
         when class in [:ambiguous_transport, :side_effect_uncertain, :timeout] do
      true
    end

    defp ambiguous_write?(_result), do: false
  else
    @spec crash(atom()) :: :ok
    def crash(_boundary), do: :ok

    @spec crash_if_ambiguous(term()) :: term()
    def crash_if_ambiguous(result), do: result
  end
end

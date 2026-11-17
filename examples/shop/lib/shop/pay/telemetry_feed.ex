defmodule Shop.Pay.TelemetryFeed do
  @moduledoc """
  Sends every Mishka Pay telemetry event to the page, so each call shows with its time and
  outcome, and a request the provider limited with the reason it gave. The handler runs in the
  caller and only broadcasts: never a key or a body.
  """

  @topic "pay:telemetry"

  @events [
    [:mishka_pay, :checkout, :stop],
    [:mishka_pay, :checkout_read, :stop],
    [:mishka_pay, :payment, :stop],
    [:mishka_pay, :refund, :stop],
    [:mishka_pay, :credentials, :stop],
    [:mishka_pay, :webhook, :stop],
    [:mishka_pay, :request, :stop],
    [:mishka_pay, :request, :retry]
  ]

  @doc "The PubSub topic the page listens on."
  def topic, do: @topic

  @doc "Attaches the handler, once, when the application starts."
  def attach, do: :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle/4, nil)

  @doc false
  def handle([:mishka_pay | name], measurements, meta, _config) do
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      at: DateTime.utc_now(),
      event: name |> Enum.reject(&(&1 == :stop)) |> Enum.join("."),
      ms: ms(measurements[:duration]),
      outcome: meta[:outcome] || meta[:status],
      detail: detail(meta)
    }

    Phoenix.PubSub.broadcast(Shop.PubSub, @topic, {:telemetry, entry})
  end

  defp ms(nil), do: nil
  defp ms(duration), do: System.convert_time_unit(duration, :native, :millisecond)

  # A request the provider limited says why (Stripe's Stripe-Rate-Limited-Reason).
  defp detail(%{method: method, path: path} = meta) do
    case meta[:rate_limit_reason] do
      nil -> "#{method |> to_string() |> String.upcase()} #{path}"
      reason -> "#{method |> to_string() |> String.upcase()} #{path} · rate limited: #{reason}"
    end
  end

  defp detail(%{type: type}) when is_binary(type), do: type

  defp detail(meta),
    do: [meta[:provider], meta[:tenant]] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
end

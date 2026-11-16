# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.CheckoutField do
  @moduledoc """
  A question the provider's checkout page asks the buyer, such as "Name on the certificate" or
  "Which site is this for": a field of `MishkaPay.Checkout`'s `:fields` (Stripe takes three). The
  answers come back on the checkout read again, in its `:field_values`. A guarded_struct.

    * `:key`: the caller's own name for it, letters and digits, up to 200 characters.
    * `:label`: what the buyer reads, up to 50 characters.
    * `:type`: `:text` (the default), `:numeric`, or `:dropdown` with its `:options`, each
      `%{value: "pro", label: "Pro"}`.
    * `:optional`: `true` lets the buyer leave it empty.
  """

  use GuardedStruct

  guardedstruct authorized_fields: true, main_validator: {__MODULE__, :options_fit} do
    field :key, String.t(),
      enforce: true,
      derives:
        "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=200, regex=^[A-Za-z0-9]+$)"

    field :label, String.t(),
      enforce: true,
      derives: "sanitize(trim) validate(not_nil_value, string, not_empty, max_len=50)"

    field :type, :text | :numeric | :dropdown,
      default: :text,
      derives: "validate(not_nil_value, enum=Atom[text::numeric::dropdown])",
      validator: {__MODULE__, :type}

    field :options, list(), derives: "validate(list)"
    field :optional, boolean(), default: false, derives: "validate(boolean)"
  end

  @doc false
  def type(field, value),
    do: MishkaPay.Helpers.Choice.atom(field, value, ~w(text numeric dropdown))

  # A dropdown has from one to two hundred options, each a value and a label; other types none.
  @doc false
  def options_fit(attrs) do
    type = attrs |> key(:type) |> to_string()
    options = key(attrs, :options)

    cond do
      type == "dropdown" and
          not (is_list(options) and options != [] and Enum.all?(options, &option?/1)) ->
        {:error,
         %{field: :options, action: :options, message: MishkaPay.Messages.text(:dropdown_options)}}

      type != "dropdown" and options not in [nil, []] ->
        {:error,
         %{field: :options, action: :options, message: MishkaPay.Messages.text(:dropdown_options)}}

      true ->
        {:ok, attrs}
    end
  end

  defp option?(option), do: is_binary(key(option, :value)) and is_binary(key(option, :label))

  defp key(%{} = map, name), do: Map.get(map, name) || Map.get(map, Atom.to_string(name))
  defp key(_not_a_map, _name), do: nil
end

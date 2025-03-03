defmodule BanchanWeb.Components.Form.MultipleSelect do
  @moduledoc """
  Banchan-specific TextInput.
  """
  use BanchanWeb, :component

  alias Surface.Components.Form.{ErrorTag, Field, Label, MultipleSelect}
  alias Surface.Components.Form.Input.InputContext

  prop name, :any, required: true
  prop opts, :keyword, default: []
  prop class, :css_class
  prop label, :string
  prop show_label, :boolean, default: true
  prop icon, :string
  prop options, :any, default: []

  def render(assigns) do
    ~F"""
    <Field class="field" name={@name}>
      {#if @show_label}
        {#if @label}
          <Label class="label">
            {@label}
          </Label>
        {#else}
          <Label class="label" />
        {/if}
      {/if}
      <div class="flex flex-col">
        <div class="flex flex-row gap-2">
          {#if @icon}
            <span class="icon text-2xl my-auto">
              <i class={"fas fa-#{@icon}"} />
            </span>
          {/if}
          <div class="control w-full">
            <InputContext :let={form: form, field: field}>
              <MultipleSelect
                class={
                  "textarea",
                  "textarea-bordered",
                  "w-full",
                  @class,
                  "textarea-error": !Enum.empty?(Keyword.get_values(form.errors, field))
                }
                opts={@opts}
                options={@options}
              />
            </InputContext>
          </div>
          <ErrorTag class="help is-danger" />
        </div>
      </div>
    </Field>
    """
  end
end

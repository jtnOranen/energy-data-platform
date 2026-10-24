-- Daily Databricks usage and its list-price cost per product and SKU, for this workspace. List
-- price, not the invoice: Azure bills Databricks through the Azure invoice, which the budget
-- alerts watch; this shows where the DBUs go.
with

usage as (
    select * from {{ source('system_billing', 'usage') }}
    where workspace_id = '{{ var("workspace_id") }}'
),

prices as (
    select
        sku_name,
        usage_unit,
        currency_code,
        price_start_time,
        price_end_time,
        cast(pricing['default'] as double) as list_price_per_unit
    from {{ source('system_billing', 'list_prices') }}
),

priced as (
    select
        usage.usage_date,
        usage.billing_origin_product,
        usage.sku_name,
        usage.usage_unit,
        cast(usage.usage_quantity as double) as usage_quantity,
        prices.list_price_per_unit,
        prices.currency_code
    from usage
    left join prices
        on
            usage.sku_name = prices.sku_name
            and usage.usage_unit = prices.usage_unit
            and usage.usage_start_time >= prices.price_start_time
            and (prices.price_end_time is null or usage.usage_start_time < prices.price_end_time)
),

final as (
    select
        usage_date,
        billing_origin_product,
        sku_name,
        usage_unit,
        any_value(currency_code) as currency_code,
        sum(usage_quantity) as usage_quantity,
        sum(usage_quantity * list_price_per_unit) as list_cost
    from priced
    group by usage_date, billing_origin_product, sku_name, usage_unit
)

select * from final

library(dplyr)
library(readr)
library(lubridate)
library(jsonlite)
library(forecast)
library(zoo)
library(stringr)

cat("=== Loading datasets ===\n")
data_path <- "e:/ITA0404- R PROGRAMMING/capstone/E COMMERCE PROJECT/Datasets/"
out_path  <- "e:/ITA0404- R PROGRAMMING/capstone/E COMMERCE PROJECT/"

orders       <- read_csv(paste0(data_path, "olist_orders_dataset.csv"), show_col_types=FALSE)
items        <- read_csv(paste0(data_path, "olist_order_items_dataset.csv"), show_col_types=FALSE)
payments     <- read_csv(paste0(data_path, "olist_order_payments_dataset.csv"), show_col_types=FALSE)
reviews      <- read_csv(paste0(data_path, "olist_order_reviews_dataset.csv"), show_col_types=FALSE)
products     <- read_csv(paste0(data_path, "olist_products_dataset.csv"), show_col_types=FALSE)
customers    <- read_csv(paste0(data_path, "olist_customers_dataset.csv"), show_col_types=FALSE)
cat_trans    <- read_csv(paste0(data_path, "product_category_name_translation.csv"), show_col_types=FALSE)
cat("Datasets loaded.\n")

# Parse timestamps
orders <- orders %>%
  mutate(order_purchase_timestamp = as.POSIXct(order_purchase_timestamp, format="%Y-%m-%d %H:%M:%S"),
         order_delivered_customer_date = as.POSIXct(order_delivered_customer_date, format="%Y-%m-%d %H:%M:%S"),
         order_estimated_delivery_date = as.POSIXct(order_estimated_delivery_date, format="%Y-%m-%d %H:%M:%S"))

delivered <- orders %>% filter(order_status == "delivered")

# ---- 1. KPIs ----
cat("Computing KPIs...\n")
total_orders    <- nrow(delivered)
total_revenue   <- sum(payments$payment_value, na.rm=TRUE)
total_products  <- nrow(products)
total_sellers   <- n_distinct(items$seller_id)
avg_order_value <- total_revenue / total_orders
avg_review      <- mean(reviews$review_score, na.rm=TRUE)
total_categories <- n_distinct(products$product_category_name, na.rm=TRUE)

kpis <- list(
  total_orders    = total_orders,
  total_revenue   = round(total_revenue, 2),
  total_products  = total_products,
  total_sellers   = total_sellers,
  avg_order_value = round(avg_order_value, 2),
  avg_review      = round(avg_review, 2),
  total_categories = total_categories
)
cat("KPIs done.\n")

# ---- 2. Monthly Revenue ----
cat("Computing monthly revenue...\n")
monthly_revenue <- delivered %>%
  left_join(payments, by="order_id") %>%
  mutate(month = floor_date(order_purchase_timestamp, "month")) %>%
  filter(!is.na(month), !is.na(payment_value)) %>%
  group_by(month) %>%
  summarise(revenue=sum(payment_value, na.rm=TRUE), orders=n(), .groups="drop") %>%
  arrange(month)
cat("Monthly revenue done.\n")

# ---- 3. ARIMA Forecast ----
cat("Running ARIMA forecast...\n")
rev_vals <- monthly_revenue$revenue
rev_ts   <- ts(rev_vals, frequency=12, start=c(as.integer(format(min(monthly_revenue$month),"%Y")),
                                                as.integer(format(min(monthly_revenue$month),"%m"))))
arima_model <- auto.arima(rev_ts, stepwise=TRUE, approximation=TRUE)
fc <- forecast(arima_model, h=6)

last_month <- max(monthly_revenue$month)
fc_months  <- seq(last_month + months(1), by="month", length.out=6)

forecast_data <- list(
  historical = list(
    labels = format(monthly_revenue$month, "%Y-%m"),
    values = round(monthly_revenue$revenue, 2),
    orders = monthly_revenue$orders
  ),
  forecast = list(
    labels  = format(fc_months, "%Y-%m"),
    mean    = round(as.numeric(fc$mean), 2),
    lower80 = round(as.numeric(fc$lower[,1]), 2),
    upper80 = round(as.numeric(fc$upper[,1]), 2),
    lower95 = round(as.numeric(fc$lower[,2]), 2),
    upper95 = round(as.numeric(fc$upper[,2]), 2)
  ),
  model = list(
    name    = as.character(arima_model),
    aic     = round(arima_model$aic, 2),
    rmse    = round(sqrt(mean(arima_model$residuals^2, na.rm=TRUE)), 2)
  )
)
cat("ARIMA done. Model:", as.character(arima_model), "\n")

# ---- 4. Top Categories ----
cat("Computing top categories...\n")
items_enriched <- items %>%
  left_join(products, by="product_id") %>%
  left_join(cat_trans, by="product_category_name")

top_categories <- items_enriched %>%
  filter(!is.na(product_category_name_english)) %>%
  group_by(product_category_name_english) %>%
  summarise(revenue=sum(price, na.rm=TRUE), orders=n(), avg_price=mean(price,na.rm=TRUE), .groups="drop") %>%
  arrange(desc(revenue)) %>%
  head(15)
cat("Top categories done.\n")

# ---- 5. Payment Types ----
cat("Computing payment types...\n")
payment_types <- payments %>%
  group_by(payment_type) %>%
  summarise(count=n(), value=sum(payment_value, na.rm=TRUE), .groups="drop") %>%
  arrange(desc(count))

# ---- 6. Review Score Distribution ----
review_dist <- reviews %>%
  group_by(review_score) %>%
  summarise(count=n(), .groups="drop") %>%
  arrange(review_score)

# ---- 7. Order Status ----
status_dist <- orders %>%
  group_by(order_status) %>%
  summarise(count=n(), .groups="drop") %>%
  arrange(desc(count))

# ---- 8. Top States ----
cat("Computing top states...\n")
top_states <- delivered %>%
  left_join(customers, by="customer_id") %>%
  group_by(customer_state) %>%
  summarise(orders=n(), .groups="drop") %>%
  arrange(desc(orders)) %>%
  head(15)

# ---- 9. Price by Category (Box Plot Data) ----
cat("Computing price by category...\n")
price_by_cat <- items_enriched %>%
  filter(!is.na(product_category_name_english), price < 2000) %>%
  group_by(product_category_name_english) %>%
  summarise(
    median_price = median(price, na.rm=TRUE),
    q1           = quantile(price, 0.25, na.rm=TRUE),
    q3           = quantile(price, 0.75, na.rm=TRUE),
    whisker_low  = quantile(price, 0.05, na.rm=TRUE),
    whisker_high = quantile(price, 0.95, na.rm=TRUE),
    avg_price    = mean(price, na.rm=TRUE),
    .groups="drop"
  ) %>%
  arrange(desc(median_price)) %>%
  head(12)

# ---- 10. Delivery Time Analysis ----
cat("Computing delivery analytics...\n")
delivery_df <- delivered %>%
  mutate(
    delivery_days = as.numeric(difftime(order_delivered_customer_date, order_purchase_timestamp, units="days")),
    on_time       = !is.na(order_delivered_customer_date) & !is.na(order_estimated_delivery_date) &
                    (order_delivered_customer_date <= order_estimated_delivery_date)
  ) %>%
  filter(!is.na(delivery_days), delivery_days > 0, delivery_days < 100)

on_time_count  <- sum(delivery_df$on_time, na.rm=TRUE)
late_count     <- sum(!delivery_df$on_time, na.rm=TRUE)

# Delivery histogram (bins of 5 days)
d_breaks <- seq(0, 100, by=5)
d_hist   <- hist(delivery_df$delivery_days, breaks=d_breaks, plot=FALSE)

delivery_stats <- list(
  avg_days       = round(mean(delivery_df$delivery_days, na.rm=TRUE), 1),
  median_days    = round(median(delivery_df$delivery_days, na.rm=TRUE), 1),
  on_time_count  = on_time_count,
  late_count     = late_count,
  on_time_pct    = round(on_time_count / (on_time_count + late_count) * 100, 1),
  histogram      = list(labels=paste0(d_breaks[-length(d_breaks)], "-", d_breaks[-1]), counts=d_hist$counts)
)

# ---- 11. Installment Distribution ----
installment_dist <- payments %>%
  filter(!is.na(payment_installments), payment_installments >= 1, payment_installments <= 12) %>%
  group_by(payment_installments) %>%
  summarise(count=n(), .groups="drop") %>%
  arrange(payment_installments)

# ---- 12. Price Histogram ----
p_breaks  <- seq(0, 500, by=25)
p_hist    <- hist(items$price[!is.na(items$price) & items$price < 500], breaks=p_breaks, plot=FALSE)
price_hist_data <- list(
  labels = paste0("R$", p_breaks[-length(p_breaks)]),
  counts = p_hist$counts
)

# ---- 13. Weekly Orders ----
cat("Computing weekly orders...\n")
weekly_orders <- delivered %>%
  mutate(week=floor_date(order_purchase_timestamp, "week")) %>%
  filter(!is.na(week)) %>%
  group_by(week) %>%
  summarise(orders=n(), .groups="drop") %>%
  arrange(week)

# ---- 14. Revenue by Month + Cumulative ----
monthly_revenue <- monthly_revenue %>%
  mutate(cumulative_revenue = cumsum(revenue))

# ---- 15. Freight vs Price ----
freight_sample <- items_enriched %>%
  filter(!is.na(price), !is.na(freight_value), price < 600, freight_value < 100) %>%
  sample_n(min(1500, n())) %>%
  select(price, freight_value, product_category_name_english)

# ---- Compile all ----
cat("Compiling dashboard data...\n")
dashboard_data <- list(
  kpis = kpis,
  monthly_revenue = list(
    labels     = format(monthly_revenue$month, "%b %Y"),
    values     = round(monthly_revenue$revenue, 2),
    orders     = monthly_revenue$orders,
    cumulative = round(monthly_revenue$cumulative_revenue, 2)
  ),
  forecast = forecast_data,
  top_categories = list(
    labels    = top_categories$product_category_name_english,
    revenue   = round(top_categories$revenue, 2),
    orders    = top_categories$orders,
    avg_price = round(top_categories$avg_price, 2)
  ),
  payment_types = list(
    labels = payment_types$payment_type,
    counts = payment_types$count,
    values = round(payment_types$value, 2)
  ),
  review_dist = list(
    scores = review_dist$review_score,
    counts = review_dist$count
  ),
  status_dist = list(
    labels = status_dist$order_status,
    counts = status_dist$count
  ),
  top_states = list(
    labels = top_states$customer_state,
    orders = top_states$orders
  ),
  price_by_cat = list(
    labels       = price_by_cat$product_category_name_english,
    median_price = round(price_by_cat$median_price, 2),
    q1           = round(price_by_cat$q1, 2),
    q3           = round(price_by_cat$q3, 2),
    whisker_low  = round(price_by_cat$whisker_low, 2),
    whisker_high = round(price_by_cat$whisker_high, 2),
    avg_price    = round(price_by_cat$avg_price, 2)
  ),
  delivery = delivery_stats,
  installments = list(
    labels = installment_dist$payment_installments,
    counts = installment_dist$count
  ),
  price_hist = price_hist_data,
  weekly_orders = list(
    labels = format(weekly_orders$week, "%Y-%m-%d"),
    counts = weekly_orders$orders
  ),
  freight_scatter = list(
    price         = round(freight_sample$price, 2),
    freight_value = round(freight_sample$freight_value, 2),
    category      = freight_sample$product_category_name_english
  )
)

json_out <- toJSON(dashboard_data, auto_unbox=TRUE, pretty=TRUE)
writeLines(json_out, paste0(out_path, "dashboard_data.json"))
cat("\n=== dashboard_data.json exported successfully! ===\n")
cat("File:", paste0(out_path, "dashboard_data.json"), "\n")

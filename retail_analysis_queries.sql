CREATE DATABASE retail_analytics;
USE retail_analytics;

-- 1 Executive KPIs
SELECT COUNT(distinct t.invoice) AS total_orders,
	COUNT(distinct t.customer_id) AS total_customers,
	ROUND(SUM(t.revenue),2) AS total_revenue,
	ROUND(SUM(t.revenue)/COUNT(DISTINCT t.invoice),2) AS avg_order_value,
    ROUND(
        100.0 * COUNT(DISTINCT CASE WHEN c.total_orders > 1 THEN c.customer_id END)
        / COUNT(DISTINCT c.customer_id), 2
    ) AS repeat_purchase_rate_pct
FROM transactions t
JOIN customers c ON t.customer_id = c.customer_id;

-- 2 Monthly Revenue Trend
SELECT invoice_yearmonth,
ROUND(SUM(revenue),2) AS monthly_revenue,
LAG(ROUND(SUM(revenue),2)) OVER(ORDER BY invoice_yearmonth) AS previous_month_revenue
FROM transactions
GROUP BY invoice_yearmonth
ORDER BY invoice_yearmonth;

-- 3 New VS Returning Customers
WITH customer_first_period AS (
    SELECT customer_id, MIN(invoice_yearmonth) AS first_period
    FROM transactions
    GROUP BY customer_id
),
order_classified AS (
    SELECT 
        t.customer_id,
        t.invoice_yearmonth AS period,
        CASE WHEN t.invoice_yearmonth = f.first_period THEN 'New' ELSE 'Returning' END AS customer_type,
        t.revenue
    FROM transactions t
    JOIN customer_first_period f ON t.customer_id = f.customer_id
)
SELECT 
    period,
    customer_type,
    COUNT(DISTINCT customer_id) AS customers,
    ROUND(SUM(revenue), 2) AS revenue
FROM order_classified
GROUP BY period, customer_type
ORDER BY period;

-- Customer Frequency Segmentation 
SELECT
    CASE
        WHEN total_orders = 1 THEN 'One-Time'
        WHEN total_orders <= 3 THEN 'Occasional (2-3)'
        WHEN total_orders <= 6 THEN 'Regular (4-6)'
        WHEN total_orders <= 12 THEN 'Frequent (7-12)'
        ELSE 'High Frequency (13+)'
    END AS frequency_bucket,
    COUNT(customer_id) AS customers,
    ROUND(SUM(lifetime_revenue), 2) AS total_revenue
FROM customers
GROUP BY frequency_bucket
ORDER BY frequency_bucket;

-- 4 Cohort Retention
WITH customer_cohorts AS (
    SELECT customer_id, MIN(invoice_yearmonth) AS cohort_month
    FROM transactions
    GROUP BY customer_id
),
customer_activity AS (
    SELECT 
        t.customer_id,
        cc.cohort_month,
        (YEAR(STR_TO_DATE(CONCAT(t.invoice_yearmonth, '-01'), '%Y-%m-%d')) 
         - YEAR(STR_TO_DATE(CONCAT(cc.cohort_month, '-01'), '%Y-%m-%d'))) * 12
        + (MONTH(STR_TO_DATE(CONCAT(t.invoice_yearmonth, '-01'), '%Y-%m-%d')) 
         - MONTH(STR_TO_DATE(CONCAT(cc.cohort_month, '-01'), '%Y-%m-%d'))) AS month_number
    FROM transactions t
    JOIN customer_cohorts cc ON t.customer_id = cc.customer_id
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_size
    FROM customer_cohorts
    GROUP BY cohort_month
),
retention_counts AS (
    SELECT cohort_month, month_number, COUNT(DISTINCT customer_id) AS active_customers
    FROM customer_activity
    GROUP BY cohort_month, month_number
),
retention_with_rate AS (
    SELECT 
        r.cohort_month,
        r.month_number,
        r.active_customers,
        cs.cohort_size,
        ROUND(r.active_customers / cs.cohort_size * 100, 2) AS retention_rate
    FROM retention_counts r
    JOIN cohort_sizes cs ON r.cohort_month = cs.cohort_month
),
avg_curve AS (
    SELECT 
        month_number,
        ROUND(AVG(retention_rate), 2) AS avg_retention_pct,
        ROUND(MIN(retention_rate), 2) AS min_retention_pct
    FROM retention_with_rate
    GROUP BY month_number
)
SELECT 
    r.cohort_month,
    r.month_number,
    r.active_customers,
    r.cohort_size,
    r.retention_rate,
    a.avg_retention_pct,
    a.min_retention_pct
FROM retention_with_rate r
JOIN avg_curve a ON r.month_number = a.month_number
ORDER BY r.cohort_month, r.month_number;
   
   -- 5 RFM Segmentation 
   -- Score each customer on Recency, Frequency, Monetary and assign segment label
WITH rfm_scores AS (
    SELECT 
        customer_id,
        recency_days,
        total_orders,
        lifetime_revenue,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(5) OVER (ORDER BY total_orders ASC) AS f_score,
        NTILE(5) OVER (ORDER BY lifetime_revenue ASC) AS m_score
    FROM customers
)
SELECT 
    customer_id,
    recency_days,
    total_orders,
    lifetime_revenue,
    r_score,
    f_score,
    m_score,
    CASE 
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
        WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal Customers'
        WHEN r_score >= 4 AND f_score <= 2 THEN 'New Customers'
        WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
        WHEN r_score <= 2 AND f_score <= 2 THEN 'Lost'
        ELSE 'Needs Attention'
    END AS segment
FROM rfm_scores
ORDER BY m_score DESC;

WITH rfm_scores AS (
    SELECT 
        customer_id, recency_days, total_orders, lifetime_revenue,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(5) OVER (ORDER BY total_orders ASC) AS f_score,
        NTILE(5) OVER (ORDER BY lifetime_revenue ASC) AS m_score
    FROM customers
),
rfm_segmented AS (
    SELECT 
        customer_id, recency_days, total_orders, lifetime_revenue,
        r_score, f_score, m_score,
        CASE 
            WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
            WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal Customers'
            WHEN r_score >= 4 AND f_score <= 2 THEN 'New Customers'
            WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
            WHEN r_score <= 2 AND f_score <= 2 THEN 'Lost'
            ELSE 'Needs Attention'
        END AS segment
    FROM rfm_scores
)
SELECT 
    segment,
    COUNT(customer_id) AS customers,
    ROUND(SUM(lifetime_revenue), 2) AS total_revenue,
    ROUND(AVG(lifetime_revenue), 2) AS avg_ltv,
    ROUND(AVG(total_orders), 1) AS avg_orders,
    ROUND(AVG(recency_days), 0) AS avg_recency_days
FROM rfm_segmented
GROUP BY segment
ORDER BY total_revenue DESC;

-- 6 Product Performance
SELECT stock_code,description,
ROUND(SUM(revenue),2) AS  total_revenue,
COUNT(DISTINCT customer_id)AS unique_buyers
FROM transactions 
GROUP BY  stock_code,description
ORDER BY total_revenue DESC 
LIMIT 20;

-- 7 Geographic Analysis
SELECT country,
COUNT(DISTINCT customer_id) AS total_customers,
ROUND(SUM(revenue),2) AS total_revenue
FROM transactions
GROUP BY country 
ORDER BY total_revenue DESC;
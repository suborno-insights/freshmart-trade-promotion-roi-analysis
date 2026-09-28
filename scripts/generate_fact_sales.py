"""
Generates Fact_Sales.csv — transaction/line-item grain, ~800K rows.

Simulates real, discoverable patterns rather than random data:
  - Bangladesh weekend (Fri-Sat) and seasonal-event demand multipliers
  - Promotion-driven sales lift (type-specific factor)
  - Cannibalization: non-promoted same-category products lose share
    while a category-mate is on promotion
  - Forward-buying: a product's sales dip for 5 days after its own
    promotion ends
  - Promotion mechanic -> price fields, matching real POS capture:
    Percentage/Flat discount adjust actual_unit_price directly;
    BOGO produces two line items (paid + free); Bundle keeps the
    regular price and records the saving in discount_amount.

Requires dim_calendar.csv, dim_product.csv, dim_store.csv,
fact_promotion.csv to already exist in the same folder.

See DECISION_LOG.md, Decision 2.12 and 2.13 for full reasoning
including why each modeling choice was made.
"""
import csv
import random
import numpy as np

random.seed(7)
np.random.seed(7)

LIFT_FACTOR = {1: 1.8, 2: 1.5, 3: 2.3, 4: 1.6}  # Percentage, Flat, BOGO, Bundle
CANNIBALIZATION_FACTOR = 0.85
FORWARD_BUY_FACTOR = 0.65
FORWARD_BUY_WINDOW_DAYS = 5
WEEKEND_MULT = 1.3
SEASON_MULT = 1.4
BASE_TXN_PER_STORE_DAY = 15

QTY_CHOICES = [1, 2, 3]
QTY_WEIGHTS = [0.5, 0.35, 0.15]


def load_data():
    dates, is_weekend, is_season = [], [], []
    with open("dim_calendar.csv") as f:
        for row in csv.DictReader(f):
            dates.append(row["date"])
            is_weekend.append(row["is_weekend"] == "1")
            is_season.append(row["is_season_event"] == "1")

    with open("dim_product.csv") as f:
        products = list(csv.DictReader(f))

    with open("dim_store.csv") as f:
        stores = [int(row["store_id"]) for row in csv.DictReader(f)]

    with open("fact_promotion.csv") as f:
        promos = list(csv.DictReader(f))

    return dates, is_weekend, is_season, products, stores, promos


def build_promo_arrays(dates, products, promos):
    date_to_idx = {d: i for i, d in enumerate(dates)}
    n_days = len(dates)
    product_ids = [int(p["product_id"]) for p in products]
    n_products = len(product_ids)
    pid_to_idx = {pid: i for i, pid in enumerate(product_ids)}
    category_of = {int(p["product_id"]): p["category"] for p in products}
    categories = sorted(set(category_of.values()))
    cat_idx = {c: i for i, c in enumerate(categories)}

    active_promo_id = np.full((n_products, n_days), -1, dtype=int)
    forward_buy = np.zeros((n_products, n_days), dtype=bool)
    promo_details = {}

    for row in promos:
        promo_id = int(row["promotion_id"])
        pidx = pid_to_idx[int(row["product_id"])]
        s_idx, e_idx = date_to_idx[row["start_date"]], date_to_idx[row["end_date"]]
        active_promo_id[pidx, s_idx:e_idx + 1] = promo_id
        fb_start, fb_end = e_idx + 1, min(e_idx + FORWARD_BUY_WINDOW_DAYS, n_days - 1)
        if fb_start <= fb_end:
            forward_buy[pidx, fb_start:fb_end + 1] = True
        promo_details[promo_id] = dict(
            type_id=int(row["promotion_type_id"]),
            discount_pct=float(row["discount_percentage"]) if row["discount_percentage"] else None,
            flat_amt=float(row["flat_discount_amount"]) if row["flat_discount_amount"] else None,
            bundle_qty=int(row["bundle_quantity"]) if row["bundle_quantity"] else None,
            bundle_price=float(row["bundle_price"]) if row["bundle_price"] else None,
        )

    category_active = np.zeros((len(categories), n_days), dtype=bool)
    for pidx, pid in enumerate(product_ids):
        c = cat_idx[category_of[pid]]
        category_active[c] |= (active_promo_id[pidx] != -1)

    return dict(product_ids=product_ids, pid_to_idx=pid_to_idx, category_of=category_of,
                cat_idx=cat_idx, active_promo_id=active_promo_id, forward_buy=forward_buy,
                category_active=category_active, promo_details=promo_details)


def generate(out_path="fact_sales.csv"):
    dates, is_weekend, is_season, products, stores, promos = load_data()
    ctx = build_promo_arrays(dates, products, promos)
    product_ids = ctx["product_ids"]
    regular_price = {int(p["product_id"]): float(p["regular_unit_price"]) for p in products}
    n_days = len(dates)

    out = open(out_path, "w", newline="", encoding="utf-8")
    w = csv.writer(out)
    w.writerow(["sale_line_id", "transaction_id", "transaction_datetime", "store_id", "product_id",
                "quantity", "actual_unit_price", "discount_amount", "promotion_id"])

    sale_line_id, transaction_id = 1, 1

    for d_idx in range(n_days):
        weights = np.ones(len(product_ids))
        for pidx, pid in enumerate(product_ids):
            promo_id = ctx["active_promo_id"][pidx, d_idx]
            if promo_id != -1:
                t = ctx["promo_details"][promo_id]["type_id"]
                weights[pidx] = LIFT_FACTOR[t]
            elif ctx["forward_buy"][pidx, d_idx]:
                weights[pidx] = FORWARD_BUY_FACTOR
            else:
                c = ctx["cat_idx"][ctx["category_of"][pid]]
                weights[pidx] = CANNIBALIZATION_FACTOR if ctx["category_active"][c, d_idx] else 1.0
        probs = weights / weights.sum()

        day_mult = 1.0
        if is_weekend[d_idx]:
            day_mult *= WEEKEND_MULT
        if is_season[d_idx]:
            day_mult *= SEASON_MULT

        for store_id in stores:
            n_txn = max(1, int(round(np.random.normal(BASE_TXN_PER_STORE_DAY * day_mult, 2))))
            for _ in range(n_txn):
                n_items = np.random.choice([1, 2, 3, 4], p=[0.35, 0.35, 0.2, 0.1])
                picks = np.random.choice(product_ids, size=n_items, p=probs, replace=True)
                dt_str = f"{dates[d_idx]}T{random.randint(9,20):02d}:{random.randint(0,59):02d}:{random.randint(0,59):02d}"

                for pid in picks:
                    pidx = ctx["pid_to_idx"][int(pid)]
                    promo_id = ctx["active_promo_id"][pidx, d_idx]
                    reg_price = regular_price[int(pid)]

                    if promo_id == -1:
                        qty = int(np.random.choice(QTY_CHOICES, p=QTY_WEIGHTS))
                        w.writerow([sale_line_id, transaction_id, dt_str, store_id, int(pid),
                                    qty, round(reg_price, 2), 0, ""])
                        sale_line_id += 1
                        continue

                    det = ctx["promo_details"][int(promo_id)]
                    t = det["type_id"]
                    if t == 1:  # Percentage discount
                        qty = int(np.random.choice(QTY_CHOICES, p=QTY_WEIGHTS))
                        price = round(reg_price * (1 - det["discount_pct"] / 100), 2)
                        w.writerow([sale_line_id, transaction_id, dt_str, store_id, int(pid),
                                    qty, price, 0, int(promo_id)])
                        sale_line_id += 1
                    elif t == 2:  # Flat discount
                        qty = int(np.random.choice(QTY_CHOICES, p=QTY_WEIGHTS))
                        price = round(reg_price - det["flat_amt"], 2)
                        w.writerow([sale_line_id, transaction_id, dt_str, store_id, int(pid),
                                    qty, price, 0, int(promo_id)])
                        sale_line_id += 1
                    elif t == 3:  # BOGO -> two lines: paid + free
                        w.writerow([sale_line_id, transaction_id, dt_str, store_id, int(pid),
                                    1, round(reg_price, 2), 0, int(promo_id)])
                        sale_line_id += 1
                        w.writerow([sale_line_id, transaction_id, dt_str, store_id, int(pid),
                                    1, 0, 0, int(promo_id)])
                        sale_line_id += 1
                    elif t == 4:  # Bundle -> regular price + discount_amount adjustment
                        qty = det["bundle_qty"]
                        disc = round(qty * reg_price - det["bundle_price"], 2)
                        w.writerow([sale_line_id, transaction_id, dt_str, store_id, int(pid),
                                    qty, round(reg_price, 2), disc, int(promo_id)])
                        sale_line_id += 1
                transaction_id += 1

    out.close()
    print("Total sale_line rows:", sale_line_id - 1)
    print("Total transactions:", transaction_id - 1)


if __name__ == "__main__":
    generate()

"""
Generates Fact_Promotion.csv — 475 promotion events across 36 products
(national-level; no division_id — see DECISION_LOG.md Decision 2.11).
~55% of events are scheduled around Dim_Calendar seasonal windows,
the rest at random dates, so the dataset contains both season-linked
and non-season promotion examples for comparison.

Requires dim_product.csv to already exist (product_id, regular_unit_price).
See DECISION_LOG.md, Decision 2.10 and 2.11 for full reasoning.
"""
import csv
import random
from datetime import date, timedelta

random.seed(42)

start_range = date(2023, 10, 1)
end_range = date(2026, 9, 30)

type_weights = [0.40, 0.25, 0.20, 0.15]  # Percentage, Flat, BOGO, Bundle

# Same season centers used to build Dim_Calendar's event windows
season_centers = [
    date(2023, 10, 24), date(2024, 4, 10), date(2024, 6, 17), date(2024, 10, 12),
    date(2025, 3, 31), date(2025, 6, 7), date(2025, 10, 2), date(2026, 3, 20),
    date(2023, 12, 26), date(2024, 12, 26), date(2025, 12, 26),
    date(2023, 11, 25), date(2024, 11, 29), date(2025, 11, 28),
    date(2024, 4, 12), date(2025, 4, 12), date(2026, 4, 12),
]


def load_products(path="dim_product.csv"):
    with open(path) as f:
        return list(csv.DictReader(f))


def generate(products):
    rows = []
    promo_id = 1
    for p in products:
        pid = int(p["product_id"])
        reg_price = float(p["regular_unit_price"])
        n_events = random.randint(11, 15)  # ~13 avg per product -> ~468-475 total
        used_ranges = []
        attempts, events_made = 0, 0
        while events_made < n_events and attempts < 60:
            attempts += 1
            if random.random() < 0.55:
                center = random.choice(season_centers)
                s = center + timedelta(days=random.randint(-3, 3))
            else:
                days_span = (end_range - start_range).days
                s = start_range + timedelta(days=random.randint(0, days_span))
            e = s + timedelta(days=random.randint(3, 10))
            if s < start_range or e > end_range:
                continue
            if any(not (e < us or s > ue) for us, ue in used_ranges):
                continue
            used_ranges.append((s, e))

            ptype = random.choices([1, 2, 3, 4], weights=type_weights)[0]
            discount_pct = flat_amt = free_units = bundle_qty = bundle_price = ""
            if ptype == 1:
                discount_pct = round(random.uniform(10, 30), 1)
            elif ptype == 2:
                flat_amt = round(reg_price * random.uniform(0.08, 0.18), 2)
            elif ptype == 3:
                free_units = 1
            elif ptype == 4:
                bundle_qty = random.choice([2, 3])
                bundle_price = round(reg_price * bundle_qty * (1 - random.uniform(0.10, 0.20)), 2)

            rows.append([promo_id, pid, ptype, s.isoformat(), e.isoformat(),
                         discount_pct, flat_amt, free_units, bundle_qty, bundle_price])
            promo_id += 1
            events_made += 1
    return rows


if __name__ == "__main__":
    products = load_products()
    rows = generate(products)
    with open("fact_promotion.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["promotion_id", "product_id", "promotion_type_id", "start_date", "end_date",
                     "discount_percentage", "flat_discount_amount", "free_units_per_purchase",
                     "bundle_quantity", "bundle_price"])
        w.writerows(rows)
    print("Total promotion events:", len(rows))

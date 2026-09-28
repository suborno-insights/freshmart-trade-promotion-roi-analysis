"""
Generates Dim_Calendar.csv — daily grain, Oct 2023 to Sep 2026.
Flags Bangladesh weekend (Friday-Saturday) and seasonal shopping
event windows (Eid-ul-Fitr, Eid-ul-Adha, Pohela Boishakh, Durga
Puja, Black Friday, Year-End Sale) using real event dates per year,
since these are lunar/lunisolar and shift annually.

See DECISION_LOG.md, Decision 2.8 for the full reasoning.
"""
import csv
from datetime import date, timedelta

start = date(2023, 10, 1)
end = date(2026, 9, 30)

# Real-world approximate dates for each year (lunar/lunisolar events shift yearly)
eid_fitr = [date(2024, 4, 10), date(2025, 3, 31), date(2026, 3, 20)]
eid_adha = [date(2023, 6, 29), date(2024, 6, 17), date(2025, 6, 7)]
puja_main = [date(2023, 10, 24), date(2024, 10, 12), date(2025, 10, 2)]
black_friday = [date(2023, 11, 24), date(2024, 11, 29), date(2025, 11, 28)]


def in_window(d, event_date, days_before, days_after=0):
    return event_date - timedelta(days=days_before) <= d <= event_date + timedelta(days=days_after)


def generate():
    rows = []
    d = start
    while d <= end:
        season_name = None
        if d.month == 4 and 10 <= d.day <= 14:
            season_name = "Pohela Boishakh"
        for ev in eid_fitr:
            if in_window(d, ev, 10):
                season_name = "Eid-ul-Fitr"
        for ev in eid_adha:
            if in_window(d, ev, 7):
                season_name = "Eid-ul-Adha"
        for ev in puja_main:
            if in_window(d, ev, 5):
                season_name = "Durga Puja"
        for ev in black_friday:
            if in_window(d, ev, 0, 2):
                season_name = "Black Friday"
        if d.month == 12 and 20 <= d.day <= 31:
            season_name = "Year-End Sale"

        day_name = d.strftime("%A")
        is_weekend = 1 if day_name in ("Friday", "Saturday") else 0  # BD weekend
        quarter = (d.month - 1) // 3 + 1

        rows.append([
            d.isoformat(), day_name, d.isocalendar()[1], d.month, d.strftime("%B"),
            quarter, d.year, is_weekend,
            season_name if season_name else "", 1 if season_name else 0
        ])
        d += timedelta(days=1)
    return rows


if __name__ == "__main__":
    rows = generate()
    with open("dim_calendar.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["date", "day_name", "week", "month", "month_name", "quarter",
                     "year", "is_weekend", "season_event_name", "is_season_event"])
        w.writerows(rows)
    print(f"Total rows: {len(rows)}")
    print(f"Season-flagged rows: {sum(r[-1] for r in rows)}")

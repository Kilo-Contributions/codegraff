"""Money parsing and arithmetic in integer cents."""


def parse_amount(text):
    """'$1,234.50' or '-12.5' -> integer cents."""
    text = text.strip().replace("$", "")
    return int(float(text) * 100)


def format_cents(cents):
    """Integer cents -> '$1,234.50'; negative amounts as '-$12.50'."""
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return f"{sign}${cents // 100}.{cents % 100:02d}"


def split_evenly(cents, ways):
    """Split cents into `ways` integer parts that sum to cents, larger parts first."""
    share = cents // ways
    return [share] * ways

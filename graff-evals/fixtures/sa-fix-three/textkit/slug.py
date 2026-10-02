"""Text helpers."""
import re


def slugify(text):
    """Lowercase ASCII slug: words joined by single dashes, no leading or trailing dash."""
    text = text.lower()
    text = re.sub(r"[^a-z0-9]", "-", text)
    return text


def truncate(text, width, ellipsis="..."):
    """Cut text to at most width characters, ending with ellipsis when it was cut."""
    if len(text) <= width:
        return text
    return text[:width] + ellipsis


def title_case(text, minor=("a", "an", "and", "of", "the", "to")):
    """Capitalize words except minor ones; the first word is always capitalized."""
    words = text.split()
    out = []
    for w in words:
        if w.lower() in minor:
            out.append(w.lower())
        else:
            out.append(w.capitalize())
    return " ".join(out)

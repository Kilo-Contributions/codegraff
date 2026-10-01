import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from textkit.slug import slugify, title_case, truncate  # noqa: E402

assert slugify("Hello, World!") == "hello-world", slugify("Hello, World!")
assert slugify("  Many   spaces -- here ") == "many-spaces-here", slugify("  Many   spaces -- here ")
assert truncate("abcdefghij", 6) == "abc...", truncate("abcdefghij", 6)
assert truncate("short", 10) == "short"
assert title_case("the lord of the rings") == "The Lord of the Rings", title_case("the lord of the rings")
print("textkit OK")

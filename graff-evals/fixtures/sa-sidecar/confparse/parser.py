"""Parser for the .conf format the deploy tool reads."""
import os


class ConfError(ValueError):
    pass


def parse(text, base_dir=".", _seen=None):
    """Parse config text into a flat dict of "section.key" -> value."""
    seen = set() if _seen is None else _seen
    out = {}
    aliases = {}
    section = ""
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        word, _, rest = line.partition(" ")
        rest = rest.strip()
        if word == "include":
            path = os.path.normpath(os.path.join(base_dir, rest))
            if path in seen:
                raise ConfError(f"line {lineno}: include cycle at {rest}")
            seen.add(path)
            with open(path) as f:
                out.update(parse(f.read(), os.path.dirname(path), seen))
        elif word == "set":
            key, eq, value = rest.partition("=")
            if not eq:
                raise ConfError(f"line {lineno}: set needs key = value")
            out[_qualify(section, key.strip())] = _coerce(value.strip())
        elif word == "unset":
            out.pop(rest, None)
        elif word == "alias":
            name, eq, target = rest.partition("=")
            if not eq:
                raise ConfError(f"line {lineno}: alias needs name = key")
            aliases[name.strip()] = _qualify(section, target.strip())
        else:
            raise ConfError(f"line {lineno}: unknown directive {word!r}")
    for name, target in aliases.items():
        if target in out:
            out[name] = out[target]
    return out


def _qualify(section, key):
    return f"{section}.{key}" if section and "." not in key else key


def _coerce(value):
    if value in ("true", "false"):
        return value == "true"
    try:
        return int(value)
    except ValueError:
        pass
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    return value

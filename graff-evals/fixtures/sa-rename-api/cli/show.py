import sys

from core.users import fetch_user as lookup


def main(argv):
    u = lookup(int(argv[1]))
    if not u:
        return "no such user"
    return "{name} ({email})".format(**u)


if __name__ == "__main__":
    print(main(sys.argv))

import re

ANSI_ESCAPE = re.compile(
    r"\x1b\][^\x07]*(?:\x07|\x1b\\)|"
    r"\x1b[P^_].*?\x1b\\|"
    r"\x1b\[[0-?]*[ -/]*[@-~]|"
    r"\x1b[@-_]",
    re.DOTALL,
)
CONTROL_CHARACTERS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def clean_text(value: str) -> str:
    value = ANSI_ESCAPE.sub("", value)
    value = CONTROL_CHARACTERS.sub("", value)
    return value.replace("\r\n", "\n").replace("\r", "\n")

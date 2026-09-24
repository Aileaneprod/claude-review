"""Build companies.json for the invoicing scenarios.

Every identifier produced here is invented (see README.md): the SIRENs are
generated, not copied from anywhere, and each one passes the Luhn check so the
application's validator accepts it.
"""

import json

# A realistic prefix, so the numbers look like the ones the application sees.
PREFIX = "810000"

COMPANIES = [
    {"name": "Atelier Fictif", "email": "compta@atelier.example.test"},
    {"name": "Boulangerie Imaginaire", "email": "contact@boulangerie.example.test"},
    {"name": "Garage Inventé", "email": "factures@garage.example.test"},
]


def luhn_ok(digits: str) -> bool:
    total = 0
    for index, char in enumerate(reversed(digits)):
        value = int(char)
        if index % 2 == 1:
            value *= 2
            if value > 9:
                value -= 9
        total += value
    return total % 10 == 0


def siren(sequence: int) -> str:
    body = PREFIX + f"{sequence:02d}"
    for check in range(10):
        candidate = body + str(check)
        if luhn_ok(candidate):
            return candidate
    raise AssertionError("no Luhn check digit for " + body)


def main() -> None:
    rows = [dict(company, siren=siren(i + 1)) for i, company in enumerate(COMPANIES)]
    with open("companies.json", "w", encoding="utf-8") as handle:
        json.dump(rows, handle, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()

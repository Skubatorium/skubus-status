import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "generator"))
import generate_targets as g  # noqa: E402

DOMAINS = """# Domains

## ACTIVE

| Hostname | Zweck |
|---|---|
| `skubus.de` | Landingpage |
| `www.skubus.de` | Landingpage |
| `app.skubus.de` | Coolify |
| `send.skubus.de` | Resend |
| `geheim.skubus.de` | Portal |
| `leer.skubus.de` | nichts dahinter |

## PLANNED / POSSIBLE

| Hostname | Möglicher Zweck |
|---|---|
| `api.skubus.de` | später |
"""

APPS = """# Applications

## skubus

| Feld | Wert |
|---|---|
| Domain | `https://skubus.de` + `https://www.skubus.de` |

## portal

| Feld | Wert |
|---|---|
| Domain | `https://geheim.skubus.de` |
| Passwortschutz | Traefik Basic-Auth |
"""


class GeneratorTest(unittest.TestCase):
    def build(self, domains=DOMAINS, apps=APPS):
        return g.build_targets(g.parse_active_domains(domains), g.parse_applications(apps))

    def test_classification(self):
        by = {t["hostname"]: t for t in self.build()}
        self.assertEqual(by["app.skubus.de"]["kind"], "platform")
        self.assertEqual(by["send.skubus.de"]["kind"], "mail")
        self.assertEqual(by["skubus.de"]["kind"], "project")
        self.assertEqual(by["www.skubus.de"]["name"], "skubus")
        self.assertTrue(by["geheim.skubus.de"]["auth_required"])
        self.assertFalse(by["skubus.de"]["auth_required"])
        self.assertEqual(by["leer.skubus.de"]["kind"], "unassigned")
        self.assertNotIn("api.skubus.de", by)  # PLANNED wird nicht geprüft

    def test_negative_passwortschutz(self):
        apps = APPS.replace("Traefik Basic-Auth", "Kein Basic-Auth")
        by = {t["hostname"]: t for t in self.build(apps=apps)}
        self.assertFalse(by["geheim.skubus.de"]["auth_required"])

    def test_health_erwartung(self):
        apps = APPS.replace("| Passwortschutz | Traefik Basic-Auth |", "| Health-Erwartung | HTTP 401 auf `/` |")
        by = {t["hostname"]: t for t in self.build(apps=apps)}
        self.assertEqual(by["geheim.skubus.de"]["expect_codes"], [401])

    def test_missing_active_section(self):
        with self.assertRaises(g.ParseError):
            g.parse_active_domains("# Domains\n\n## PLANNED\n")

    def test_unparsable_row_fails(self):
        with self.assertRaises(g.ParseError):
            g.parse_active_domains(DOMAINS.replace("| `skubus.de` | Landingpage |", "| skubus.de | Landingpage |"))

    def test_app_host_not_in_active_fails(self):
        apps = APPS + "\n## ghost\n\n| Feld | Wert |\n|---|---|\n| Domain | `https://ghost.skubus.de` |\n"
        with self.assertRaises(g.ParseError):
            self.build(apps=apps)

    def test_app_without_domain_fails(self):
        with self.assertRaises(g.ParseError):
            g.parse_applications("## x\n\n| Feld | Wert |\n|---|---|\n| Zweck | y |\n")

    def test_missing_special_host_fails(self):
        with self.assertRaises(g.ParseError):
            self.build(domains=DOMAINS.replace("| `app.skubus.de` | Coolify |\n", ""))


if __name__ == "__main__":
    unittest.main()

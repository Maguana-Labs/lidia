# The fictional cast

Every fixture, demo library, snapshot script, prompt example, code comment and doc
in this repo uses the same made-up people and companies. Use them when you add a
test or an example, so a reader always knows who's who, and never use a real
person, customer or meeting.

## The user

| Name | Who | Email |
|---|---|---|
| **Alex Moreno** ("Alex") | The person using LidIA: a consultant at Harborcloud. "Me", "I" and "You" in fixtures. | `alex@harborcloud.example` |

## Companies

| Company | Role | Domains |
|---|---|---|
| **Harborcloud** | Alex's own company, a small cloud consultancy | `harborcloud.example`, `harborcloud.test` (the same company on two domains) |
| **Northwind** | The main customer: a "SaaS Platform on AWS" project with a weekly sync ("Northwind x Harborcloud - SaaS Platform on AWS") | `northwind.example` |
| **Pinecrest** | A second customer, with a TAPR call | `pinecrest.example` |
| **Acme** | A partner and prospect in examples | `acme.example`, `acme.com` in older tests |
| **Contoso** | A company Alex has never met (first-meeting cases) | `contoso.example` |
| **Maguana** | The project's own lab (real, public): internal meetings in the iPhone demo | |

Projects: **Northwind** (the customer project) and **Beacon** (a Northwind sub-project).
**TAPR** ("Technical Architecture & Platform Review") is the made-up acronym that
speech engines mishear as "taper"; it stands in for any domain acronym.

## People

At Northwind:

| Name | Short form | Email |
|---|---|---|
| Mateo Keller (also Mateo Kovačević, to test diacritics) | Mateo K | `mateo.k@northwind.example` |
| Daniel Reyes | Daniel R | `daniel.r@northwind.example` |
| Felix S | | `felix.s@northwind.example` |
| Hugo S | | `hugo.s@northwind.example` |
| Ana Ruiz | Ana | (iPhone demo) |
| Marco Bianchi | Marco | (iPhone demo) |

At Harborcloud:

| Name | Short form | Email |
|---|---|---|
| Leo Novak | Leo | `leo@harborcloud.test` |
| Nadia Petrenko 🇺🇦 | Nadia | `nadia@harborcloud.example` |
| Mila Horvat | Mila | `mila.horvat@harborcloud.example`, `mila@harborcloud.test` |
| Selin | | `selin@harborcloud.example` |
| Greta | | `greta@harborcloud.example` |
| Ivo | | (name only, no email) |
| Oliver Grant | | |
| Inés Navarro | Inés | (iPhone demo: a 1:1) |

At Pinecrest: **Victor** (`victor@pinecrest.example`) and **Omar Haddad**.

On the LidIA team in the iPhone demo: **Priya Shah**, **Tom Okafor**; "Sam" is a prospect.
Generic placeholders (`person@example.com`, Bob, Alice, Carol, Jane Doe) stay as they are.

## Rules

- Domains end in `.example` or `.test` (reserved, never real), except a few
  personal-mail cases that need `gmail.com`.
- A transcript fixture is written from scratch. Never paste a real one, even
  shortened or translated.
- Live tests and snapshot runs that read a copy of your own library take your
  names from the environment (`LIDIA_LIVE_USER`, `LIDIA_PROBE_USER`,
  `LIDIA_SNAPSHOT_SERIES`, `LIDIA_SNAPSHOT_PROJECT`, `LIDIA_SNAPSHOT_COMPANY`,
  `LIDIA_SNAPSHOT_OTHER_CALL`, `LIDIA_INTENTS_LIVE_TITLE`), so real names stay
  out of the code.

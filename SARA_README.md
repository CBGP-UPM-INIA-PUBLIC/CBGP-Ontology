# Sara — how to check your ontology edits before you push

Written for Sara, who edits this ontology (in Protégé or by hand) and does not work in the CBGP-Databases folder.

## The one thing to know

There is a small checker in this folder, **`check_ontology.rb`**. Run it after you
edit the ontology and **before you commit/push**. It reads
`cbgp-application-ontology.owl` and tells you about the small slips that are easy
to make and hard to spot afterwards — mainly **a label with no language tag**,
or **a class that has an English label but no Spanish one**.

Those slips don't give an error in the application. Things just quietly go
missing. (This is how the *European* and *Private* research project forms
once disappeared from the menus: their category was written without a language
tag.) The checker finds them in a second and tells you the **line number**.

## How to run it

You need Ruby (check with `ruby -v` in a terminal). Nothing else to install.

1. Open a terminal in this folder (`CBGP-Ontology`).
2. Run:

   ```
   ruby check_ontology.rb
   ```

3. Read the last line:
   - **`OK - no errors.`** — you're fine to commit and push.
   - **`FAILED - N error(s) to fix in the ontology.`** — fix them (below), save, and run it again.

*(If you don't have Ruby, tell Mark — it is only needed for this check.)*

## What the output looks like

```
Checked .../cbgp-application-ontology.owl
  611 classes, 2 error(s), 21 warning(s)

ERROR: untagged_label (1)
  line 3120  member_start_date    label "Start date" has no language tag (needs xml:lang="en" or "es")

ERROR: missing_language (1)
  line 5410  project_foo         has no label in es (has: en)

FAILED - 2 error(s) to fix in the ontology.
```

Each line gives the **line number**, the **class name**, and what's wrong. Open
`cbgp-application-ontology.owl`, go to that line, fix it, save.

## What each error means and how to fix it

| It says | What's wrong | Fix |
|---|---|---|
| `untagged_label` | A label has no language | In Protégé: edit the label annotation and fill in the **Lang** box (`en` or `es`). In the file: add `xml:lang="en"` / `xml:lang="es"` to the `<rdfs:label>` |
| `missing_language` | The class has labels but none in English, or none in Spanish | Add the missing label |
| `empty_label` | A label is blank | Fill it in, or delete it |
| `form_incomplete` | A form (a subclass of `forms`) is missing `form-category`, `dbname` or `has-fields` — it would never appear in a menu | Add the missing property, copying a similar form |
| `ui_text_placeholders` | An interface text (a subclass of `ui-text`) uses different `%{...}` names in English and Spanish | The `%{target}`-style words are filled in by the application: write them identically in both languages (only translate the words around them) |
| `ui_text_characters` | An interface text contains a back-tick, a double quote, `<`, `>`, a backslash or `${` | Remove it (use « » or typographic quotes instead) |
| `untagged_annotation` | A form's `form-category` or `dbname` has no language tag (the other forms have `xml:lang="en"`) | Add `xml:lang="en"` |

**Warnings** don't stop you; they're just worth a look:

- `duplicate_label` — two labels in the same language on one class. Probably one is a leftover.
- `untagged_comment` — a comment with no language. **This is normally fine.** The
  application only shows comments in the user's language, so an untagged comment
  is *not shown to users* — right for editor notes such as "(Deprecated)" or
  "NOT IN LAURA'S EXCEL". If you *do* want a comment to appear as help text for
  users, give it a language tag. (There are 21 of these at the moment, all deliberate-looking notes.)

## Options

```
ruby check_ontology.rb --errors-only          # hide the warnings
ruby check_ontology.rb --languages en,es,fr   # also require French labels, say
ruby check_ontology.rb some-other-file.owl    # check a different file
```

To check the checker itself: `ruby test_check_ontology.rb` (should say `0 failures, 0 errors`).

## Recent changes made in the ontology (so nothing surprises you)

Made on the Funding Commitments work — all of them are already in the file:

- **New form: "Funding Commitment"** (what share of a member's salary a project pays, and for what dates), with its own fields `commitment_member`, `commitment_project`, `commitment_percentage`, `commitment_start_date`, `commitment_end_date`, `commitment_notes`. Also new "panel" definitions (`member_commitments_panel`, `project_commitments_panel`, `commitment_siblings_panel`) that make the member, project and commitment pages list the related commitments and warn when a person's total isn't 100%.
- **`member_projects` removed** from the Member form (it is now worked out from the commitments).
- **Person fields now store the DNI/NIE/PAS instead of the ORCID** (not everyone has an ORCID) and are renamed: `project_pi_orcid` → `project_pi_nie`, `project_main_copi_orcid` → `project_main_copi_nie`, `beneficiary_orcid` → `beneficiary_nie`, `personnel_project_responsible_pi_orcid` → `personnel_project_responsible_pi_nie`. `project_dni_nie_pas` now also looks up a member by surname. (`publication_cbgp_authors` stays on ORCID on purpose.)
- **`project_application_code` is now `project_application_url` ("Application URL")** and must be a full web address (`http://` or `https://`); the call identifier on its own is rejected. It is required on all project forms, **including the user-facing one**.
- **Two new widget types** used by the above: `number` and `url`.
- **European and Private research project forms** now have `xml:lang="en"` on their `form-category` and `dbname` (they were missing from the menus without it).
- **New: interface texts (`ui-text`).** The small hints and captions the application prints around the data (for example "Type at least 2 characters to search…", the "remove" / "Add another" buttons, the search-form placeholders) are now ontology classes too, so they can be translated and corrected here: 15 subclasses of `ui-text`, each with an English and a Spanish `rdfs:label`, and a comment saying where it appears and which `%{...}` words it may contain. Edit the **labels**; **do not rename the classes** (the application finds each text by its class name). After editing, run the checker, and ask Mark to refresh the application. The Spanish is a first draft - please correct it. More of the application's text will move here over time.
- **Reminder:** if you rename or delete a field, tell Mark — the application and its tests refer to fields by name.

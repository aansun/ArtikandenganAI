# Translation log

NNAI Translator keeps a small log of how its translations go, so that model recommendations can be
based on what really happens: which model answered, how fast, and how often something went wrong.

**It stays on your Mac.** Nothing is sent anywhere. It is on by default, and you decide whether to
share a summary of it.

## What is recorded

One line per event, in `<library>/_activity-log/activity-YYYY-MM.jsonl`. Every record carries the
time, a random number for the run and the app version.

| Record | When | Fields |
|---|---|---|
| Engine check | the app looks for its engines | engine, active or not, the models chosen, state as one word (`ok`, `quota`, `auth`, `no_model`, `not_installed`, `other`) |
| Request | each request to a model | engine, model, step (classify, glossary, style, calibrate, translate, refine, inspect), seconds, characters sent and received, tokens and cost when the tool reports them, success or failure category, cut-off answer |
| Volume | a volume stops or finishes | outcome, genre, quality setting, source and target language, polish, requests at once, chunk size, duration, requests answered per model, chunks (total, retried, left untranslated, failed, layout approximated), check flags, repaired names, missing metadata |

## What is never recorded

- No text of a book or of a translation.
- No title, author, file name or folder path.
- No error message (only its category), no account name, key or other sign-in detail.

The list of allowed fields is in [`src/core/llm/activity.py`](../src/core/llm/activity.py); anything
else is dropped before writing.

## About quality

The quality numbers are **automatic signals**: retries, chunks left untranslated, layout that had to
be approximated, and flags of the checks that compare each page with its source. They show where a
model struggles. They do not judge whether the prose reads well.

## Switching it off

- In the app: **Settings > Keep a translation log**. It applies from the next book that starts or
  resumes.
- On the command line: `--no-log`, or `AGENT_LOG=0`.

Switching it off stops new records. To remove what was recorded, delete the `_activity-log` folder
(in the app: **Settings > Open folder**).

## Sharing a summary

Sharing is optional and always done by you.

1. In the app, press **Settings > Copy summary** (or run `python translate_book.py --log-report`).
2. Read what was copied.
3. Open a [translation log report](https://github.com/aansun/NNAI-Translator/issues/new?template=translation-log.yml),
   paste it, and submit.

Issues are public. The summary holds counts, speeds and model names only.

## What the shared reports taught us

Nothing yet. Findings that change a model recommendation will be written here, with the reports they
come from.
